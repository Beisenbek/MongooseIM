%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2018, Erlang-Solutions
%%% @doc
%%%
%%% @end
%%% Created : 30. Jan 2018 13:22
%%%-------------------------------------------------------------------
-module(mod_inbox).
-author("ludwikbukowski").
-include("mod_inbox.hrl").
-include("jlib.hrl").
-include("jid.hrl").
-include("mongoose_ns.hrl").
-include("mongoose.hrl").

-export([start/2, stop/1, deps/2]).
-export([process_iq/4, user_send_packet/4, filter_packet/1]).
-export([clear_inbox/2]).

-callback init(Host, Opts) -> ok when
               Host :: jid:lserver(),
               Opts :: list().

-callback get_inbox(LUsername, LServer) -> get_inbox_res() when
                    LUsername :: jid:luser(),
                    LServer :: jid:lserver().

-callback set_inbox(Username, Server, ToBareJid,
                    Content, Count, MsgId, Timestamp) -> inbox_write_res() when
                    Username :: jid:luser(),
                    Server :: jid:lserver(),
                    ToBareJid :: binary(),
                    Content :: binary(),
                    Count :: binary(),
                    MsgId :: binary(),
                    Timestamp :: erlang:timestamp().

-callback remove_inbox(Username, Server, ToBareJid) -> inbox_write_res() when
                       Username :: jid:luser(),
                       Server :: jid:lserver(),
                       ToBareJid :: binary().

-callback set_inbox_incr_unread(Username, Server, ToBareJid,
                                Content, MsgId, Timestamp) -> inbox_write_res() when
                                Username :: jid:luser(),
                                Server :: jid:lserver(),
                                ToBareJid :: binary(),
                                Content :: binary(),
                                MsgId :: binary(),
                                Timestamp :: erlang:timestamp().

-callback reset_unread(Username, Server, BareJid, MsgId) -> inbox_write_res() when
                       Username :: jid:luser(),
                       Server :: jid:lserver(),
                       BareJid :: binary(),
                       MsgId :: binary().

-callback clear_inbox(Username, Server) -> inbox_write_res() when
                      Username :: jid:luser(),
                      Server :: jid:lserver().

-spec deps(jid:lserver(), list()) -> list().
deps(_Host, Opts) ->
    groupchat_deps(Opts).

-spec start(Host :: jid:server(), Opts :: list()) -> ok.
start(Host, Opts) ->
    {ok, _} = gen_mod:start_backend_module(?MODULE, Opts, callback_funs()),
    mod_disco:register_feature(Host, ?NS_ESL_INBOX),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, no_queue),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 90),
    ejabberd_hooks:add(filter_local_packet, Host, ?MODULE, filter_packet, 90),
    store_bin_reset_markers(Host, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_ESL_INBOX, ?MODULE, process_iq, IQDisc).


-spec stop(Host :: jid:server()) -> ok.
stop(Host) ->
    mod_disco:unregister_feature(Host, ?NS_ESL_INBOX),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 90),
    ejabberd_hooks:delete(filter_local_packet, Host, ?MODULE, filter_local_packet, 90),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_ESL_INBOX).


%%%%%%%%%%%%%%%%%%%
%% Process IQ
-spec process_iq(From :: jid:jid(),
                 To :: jid:jid(),
                 Acc :: mongoose_acc:t(),
                 IQ :: jlib:iq()) -> {stop, mongoose_acc:t()} | {mongoose_acc:t(), jlib:iq()}.
process_iq(_From, _To, Acc, #iq{type = set, sub_el = SubEl} = IQ) ->
    {Acc, IQ#iq{type = error, sub_el = [SubEl, mongoose_xmpp_errors:not_allowed()]}};
process_iq(From, To, Acc, #iq{type = get, sub_el = QueryEl} = IQ) ->
    Username = From#jid.luser,
    Host = From#jid.lserver,
    List = mod_inbox_backend:get_inbox(Username, Host),
    QueryId = exml_query:attr(QueryEl, <<"queryid">>, <<>>),
    forward_messages(List, QueryId, To),
    BinCount = integer_to_binary(length(List)),
    Res = IQ#iq{type = result, sub_el = [build_result_iq(BinCount)]},
    {Acc, Res}.

-spec forward_messages(List :: list(inbox_res()),
                       QueryId :: id(),
                       To :: jid:jid()) -> list(mongoose_acc:t()).
forward_messages(List, QueryId, To) when is_list(List) ->
    Msgs = [build_inbox_message(El, QueryId) || El <- List],
    [send_message(To, Msg) || Msg <- Msgs].

-spec send_message(To :: jid:jid(), Msg :: exml:element()) -> mongoose_acc:t().
send_message(To, Msg) ->
    BareTo = jid:to_bare(To),
    ejabberd_sm:route(BareTo, To, Msg).

%%%%%%%%%%%%%%%%%%%
%% Handlers
-spec user_send_packet(Acc :: map(), From :: jid:jid(),
                       To :: jid:jid(),
                       Packet :: exml:element()) -> map().
user_send_packet(Acc, From, To, #xmlel{name = <<"message">>} = Msg) ->
    Host = From#jid.server,
    maybe_process_message(Host, From, To, Msg, outgoing),
    Acc;
user_send_packet(Acc, _From, _To, _Packet) ->
    Acc.

-type fpacket() :: {From :: jid:jid(),
                    To :: jid:jid(),
                    Acc :: mongoose_acc:t(),
                    Packet :: exml:element()}.
-spec filter_packet(Value :: fpacket() | drop) -> fpacket() | drop.
filter_packet(drop) ->
    drop;
filter_packet({From, To, Acc, Msg = #xmlel{name = <<"message">>}}) ->
    Host = To#jid.server,
    maybe_process_message(Host, From, To, Msg, incoming),
    {From, To, Acc, Msg};
filter_packet({From, To, Acc, Packet}) ->
    {From, To, Acc, Packet}.

-spec maybe_process_message(Host :: host(),
                            From :: jid:jid(),
                            To :: jid:jid(),
                            Msg :: exml:element(),
                            Dir :: outgoing | incoming) -> ok.
maybe_process_message(Host, From, To, Msg, Dir) ->
    AcceptableMessage = should_be_stored_in_inbox(Msg),
    if AcceptableMessage ->
        Type = get_message_type(Msg),
        GroupchatsEnabled = gen_mod:get_module_opt(Host, ?MODULE, groupchat, [muclight]),
        MuclightEnabled = lists:member(muclight, GroupchatsEnabled),
        Type == one2one andalso
            process_message(Host, From, To, Msg, Dir, one2one),
        (Type == groupchat andalso MuclightEnabled) andalso
            process_message(Host, From, To, Msg, Dir, groupchat);
        true ->
            ok
    end.

-spec process_message(Host :: host(),
                      From :: jid:jid(),
                      To :: jid:jid(),
                      Message :: exml:element(),
                      Dir :: outgoing | incoming,
                      Type :: one2one | groupchat) -> ok.
process_message(Host, From, To, Message, outgoing, one2one) ->
    mod_inbox_one2one:handle_outgoing_message(Host, From, To, Message);
process_message(Host, From, To, Message, incoming, one2one) ->
    mod_inbox_one2one:handle_incoming_message(Host, From, To, Message);
process_message(Host, From, To, Message, outgoing, groupchat) ->
    mod_inbox_muclight:handle_outgoing_message(Host, From, To, Message);
process_message(Host, From, To, Message, incoming, groupchat) ->
    mod_inbox_muclight:handle_incoming_message(Host, From, To, Message);
process_message(_, _, _, Message, _, _) ->
    ?WARNING_MSG("unknown messasge not written in inbox='~p'", [Message]),
    ok.


%%%%%%%%%%%%%%%%%%%
%% Stanza builders

-spec build_inbox_message(inbox_res(), id()) -> exml:element().
build_inbox_message({_Username, Content, Count, Timestamp}, QueryId) ->
    #xmlel{name = <<"message">>, attrs = [{<<"id">>, mod_inbox_utils:wrapper_id()}],
        children = [build_result_el(Content, QueryId, Count, Timestamp)]}.

-spec build_result_el(content(), id(), count(), erlang:timestamp()) -> exml:element().
build_result_el(Msg, QueryId, BinUnread, Timestamp) ->
    Forwarded = build_forward_el(Msg, Timestamp),
    QueryAttr = [{<<"queryid">>, QueryId} || QueryId =/= undefined, QueryId =/= <<>>],
    #xmlel{name = <<"result">>, attrs = [{<<"xmlns">>, ?NS_ESL_INBOX}, {<<"unread">>, BinUnread}] ++
    QueryAttr, children = [Forwarded]}.

-spec build_result_iq(count()) -> exml:element().
build_result_iq(CountBin) ->
    #xmlel{name = <<"count">>, attrs = [{<<"xmlns">>, ?NS_ESL_INBOX}],
        children = [#xmlcdata{content = CountBin}]}.

-spec build_forward_el(content(), erlang:timestamp()) -> exml:element().
build_forward_el(Content, Timestamp) ->
    {ok, Parsed} = exml:parse(Content),
    Delay = build_delay_el(Timestamp),
    #xmlel{name = <<"forwarded">>, attrs = [{<<"xmlns">>, ?NS_FORWARD}],
           children = [Delay, Parsed]}.

-spec build_delay_el(Timestamp :: erlang:timestamp()) -> exml:element().
build_delay_el({_, _, Micro} = Timestamp) ->
    {Day, {H, M, S}} = calendar:now_to_datetime(Timestamp),
    DateTimeMicro = {Day, {H, M, S, Micro}},
    jlib:timestamp_to_xml(DateTimeMicro, utc, undefined, undefined).

%%%%%%%%%%%%%%%%%%%
%% Helpers
%%

-spec store_bin_reset_markers(Host :: host(), Opts :: list()) -> boolean().
store_bin_reset_markers(Host, Opts) ->
    ResetMarkers = gen_mod:get_opt(reset_markers, Opts, [displayed]),
    ResetMarkersBin = [mod_inbox_utils:reset_marker_to_bin(Marker) || Marker <- ResetMarkers ],
    gen_mod:set_module_opt(Host, ?MODULE, reset_markers, ResetMarkersBin).

-spec get_message_type(Msg :: exml:element()) ->groupchat | one2one.
get_message_type(Msg) ->
    case exml_query:attr(Msg, <<"type">>, undefined) of
        <<"groupchat">> ->
            groupchat;
        _ ->
            one2one
    end.

-spec clear_inbox(Username :: jid:luser(), Server :: host()) -> ok.
clear_inbox(Username, Server) ->
    mod_inbox_utils:clear_inbox(Username, Server).

groupchat_deps(Opts) ->
    case lists:keyfind(groupchat, 1, Opts) of
        {groupchat, List} ->
            muclight_dep(List) ++ muc_dep(List);
        false ->
            []
    end.

muclight_dep(List) ->
    case lists:member(muclight, List) of
        true -> [{mod_muc_light, hard}];
        false -> []
    end.

muc_dep(List) ->
    case lists:member(muc, List) of
        true -> [{mod_muc, hard}];
        false -> []
    end.

callback_funs() ->
    [get_inbox, set_inbox, set_inbox_incr_unread,
        reset_unread, remove_inbox, clear_inbox].

%%%%%%%%%%%%%%%%%%%
%% Message Predicates

-spec should_be_stored_in_inbox(Msg :: exml:element()) -> boolean().
should_be_stored_in_inbox(Msg) ->
    not is_forwarded_message(Msg) andalso
        not is_error_message(Msg) andalso
        not is_offline_message(Msg).

-spec is_forwarded_message(Msg :: exml:element()) -> boolean().
is_forwarded_message(Msg) ->
    case exml_query:subelement_with_ns(Msg, ?NS_FORWARD, undefined) of
        undefined ->
            false;
        _ ->
            true
    end.

-spec is_error_message(Msg :: exml:element()) -> boolean().
is_error_message(Msg) ->
    case exml_query:attr(Msg, <<"type">>, undefined) of
        <<"error">> ->
            true;
        _ ->
            false
    end.

-spec is_offline_message(Msg :: exml:element()) -> boolean().
is_offline_message(Msg) ->
    case exml_query:subelement_with_ns(Msg, ?NS_DELAY, undefined) of
        undefined ->
            false;
        _ ->
            true
    end.
