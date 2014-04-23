-module(game_session).
-behaviour(gen_server).

-include_lib("server/include/requests.hrl").
-include_lib("server/include/settings.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([process_request/2, process_request/3]).
-export([bot_session_attach/2]).

-define(SERVER, ?MODULE).

-record(state, {
          user = undefined,
          rpc,     %% rpc process
          rpc_mon, %% rpc monitor referense
          games = [],
          rels_notif_channel = undefined,
          rels_players =[]
         }).

-record(participation, {
          game_id       :: 'GameId'(), %% generated by id_generator
          reg_num       :: integer(),
          rel_module    :: atom(),
          rel_pid       :: pid(),      %% relay, which handles communication gameman maps game_id onto pid
          tab_module    :: atom(),
          tab_pid       :: pid(),
          ref           :: any(),      %% monitor reference to relay
          role = viewer :: atom()      %% [viewer, player, ghost]
         }).

start_link(RPC) when is_pid(RPC) ->
    gen_server:start_link(?MODULE, [RPC], []).

bot_session_attach(Pid, UserInfo) ->
    gen_server:cast(Pid, {bot_session_attach, UserInfo}).

process_request(Pid, Msg) ->
    gas:info(?MODULE,"Client Request: ~p to: ~p",[Msg,Pid]),
    gen_server:call(Pid, {client_request, Msg}).

process_request(Pid, Source, Msg) ->
    gas:info(?MODULE,"Client Request ~p to: ~p from: ~p",[Msg,Pid,Source]),
    gen_server:call(Pid, {client_request, Msg}).

send_message_to_player(Pid, Message) ->
    gas:info(?MODULE,"Server Response ~p to ~p",[Message,Pid]),
    Pid ! {server,Message}, ok.

init([RPC]) ->
    MonRef = erlang:monitor(process, RPC),
    {ok, #state{rpc = RPC, rpc_mon = MonRef}}.

handle_call({client_request, Request}, From, State) ->
    handle_client_request(Request, From, State);

handle_call(Request, From, State) ->
    gas:info(?MODULE,"Unrecognized call: ~p", [Request]),
    {stop, {unknown_call, From, Request}, State}.

handle_cast({bot_session_attach, UserInfo}, State = #state{user = undefined}) ->
%    gas:info(?MODULE,"bot session attach", []),
    {noreply, State#state{user = UserInfo}};

handle_cast(Msg, State) ->
    gas:info(?MODULE,"Unrecognized cast: ~p", [Msg]),
    {stop, {error, {unknown_cast, Msg}}, State}.

handle_info({relay_event, SubscrId, RelayMsg}, State) ->
    handle_relay_message(RelayMsg, SubscrId, State);

handle_info({relay_kick, SubscrId, Reason}, State) ->
    gas:info(?MODULE,"Recived a kick notification from the table: ~p", [Reason]),
    handle_relay_kick(Reason, SubscrId, State);

handle_info({delivery, ["user_action", Action, Who, Whom], _} = Notification,
            #state{rels_players = RelsPlayers, user = User, rpc = RPC } = State) ->
    gas:info(?MODULE,"Handle_info/2 Delivery: ~p", [Notification]),
    UserId = User#'PlayerInfo'.id,
    case list_to_binary(Who) of
        UserId ->
            PlayerId = list_to_binary(Whom),
            case lists:member(PlayerId, RelsPlayers) of
                true ->
                    Type = case Action of
                               "subscribe" -> ?SOCIAL_ACTION_SUBSCRIBE;
                               "unsubscribe" -> ?SOCIAL_ACTION_UNSUBSCRIBE;
                               "block" -> ?SOCIAL_ACTION_BLOCK;
                               "unblock" -> ?SOCIAL_ACTION_UNBLOCK
                           end,
                    Msg = #social_action_msg{initiator = UserId,
                                             recipient = PlayerId,
                                             type = Type
                                            },

                    % TODO: put real db change notification from users:343 module here
                    %       wf:send_db_subscription_change
                    %       should be additionaly subscribed in bg feed worker binded to USER_EXCHANGE

                    ok = send_message_to_player(RPC, Msg);
                false ->
                    do_nothing
            end;
        _ ->
            do_nothing
    end,
    {noreply, State};

handle_info({'DOWN', MonitorRef, _Type, _Object, _Info} = Msg, State = #state{rpc_mon = MonitorRef}) ->
    gas:info("connection closed, shutting down session:~p", [Msg]),
    {stop, normal, State};

handle_info({'DOWN', OtherRef, process, _Object, Info} = _Msg,
            #state{games = Games, rpc = RPC} = State) ->
    case lists:keyfind(OtherRef, #participation.ref, Games) of
        #participation{} ->
            gas:info(?MODULE,"The table is down: ~p", [Info]),
            gas:info(?MODULE,"Closing the client and sutting down the session.", []),
            send_message_to_player(RPC,
                #disconnect{reason_id = <<"tableDown">>,
                    reason = <<"The table you are playing on is unexpectedly down.">>}),
            {stop, table_down, State};
        _ ->
            {noreply, State}
    end;

handle_info(Info, State) ->
    gas:info(?MODULE,"Unrecognized info: ~p", [Info]),
    {noreply, State}.

terminate(Reason, #state{rels_notif_channel = RelsChannel}) ->
    gas:info(?MODULE,"Terminating session: ~p", [Reason]),
    if RelsChannel =/= undefined -> nsm_mq_channel:close(RelsChannel);
       true -> do_nothing end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================

handle_client_request(#session_attach{token = Token}, _From,
                      #state{user = undefined} = State) ->
    gas:info(?MODULE,"Checking session token: ~p", [Token]),
    case auth_server:get_user_info(wf:to_binary(Token)) of
        false ->
            gas:error(?MODULE,"failed session attach: ~p", [Token]),
            {stop, normal, {error, invalid_token}, State};
        UserInfo ->
            gas:info(?MODULE,"successfull session attach. Your user info: ~p", [UserInfo]),
            {reply, UserInfo, State#state{user = UserInfo}}
    end;

handle_client_request(_, _From, #state{user = undefined} = State) ->
    gas:info(?MODULE,"Unknown session call", []),
    {reply, {error, do_session_attach_first}, State};

handle_client_request(#get_game_info{}, _From, State) ->
    gas:info(?MODULE,"Session get game info", []),
    {reply, {error, not_implemented}, State};

handle_client_request(#logout{}, _From, State) ->
    gas:info(?MODULE,"Logout", []),
    {stop, normal, ok, State};

handle_client_request(#get_player_stats{player_id = PlayerId, game_type = GameModule}, _From, #state{rpc = RPC} = State) ->
    Res = GameModule:get_player_stats(PlayerId),
    gas:info(?MODULE,"Get player stats: ~p", [Res]),
    send_message_to_player(RPC, Res),
    {reply, Res, State};

handle_client_request(#chat{chat_id = GameId, message = Msg0}, _From,
                      #state{user = User, games = Games} = State) ->
    gas:info(?MODULE,"Chat", []),
    Msg = #chat_msg{chat = GameId, content = Msg0,
                    author_id = User#'PlayerInfo'.id,
                    author_nick = User#'PlayerInfo'.login
                   },
    Participation = get_relay(GameId, Games),
    Res = case Participation of
              false ->
                  {error, chat_not_registered};
              #participation{rel_pid = Srv, rel_module = RMod} ->
                  RMod:publish(Srv, Msg)
          end,
    {reply, Res, State};

handle_client_request(#social_action_msg{type=Type, initiator=P1, recipient=P2}, _From,
                      #state{user = User} = State) when User =/= undefined ->
    UserIdBin = User#'PlayerInfo'.id,
    gas:info(?MODULE,"Social action msg from ~p to ~p (casted by ~p)", [P1, P2, UserIdBin]),
    UserId = binary_to_list(UserIdBin),
    case Type of
        ?SOCIAL_ACTION_SUBSCRIBE ->
            Subject = binary_to_list(P2),
            nsm_users:subscribe_user(UserId, Subject),
            {reply, ok, State};
        ?SOCIAL_ACTION_UNSUBSCRIBE ->
            Subject = binary_to_list(P2),
            nsm_users:remove_subscribe(UserId, Subject),
            {reply, ok, State};
        ?SOCIAL_ACTION_BLOCK ->
            Subject = binary_to_list(P2),
            wf:send(["subscription", "user", UserId, "block_user"], {Subject}),
            {reply, ok, State};
        ?SOCIAL_ACTION_UNBLOCK ->
            Subject = binary_to_list(P2),
            wf:send(["subscription", "user", UserId, "unblock_user"], {Subject}),
            {reply, ok, State};
        ?SOCIAL_ACTION_LOVE ->
            {reply, ok, State};
        ?SOCIAL_ACTION_HAMMER ->
            {reply, ok, State};
        UnknownAction ->
            gas:error(?MODULE,"Unknown social action msg from ~p to ~p: ~w", [P1,P2, UnknownAction]),
            {reply, {error, unknown_action}, State}
    end;

handle_client_request(#social_action{} = Msg, _From,
                      #state{user = User, games = Games} = State) ->
    gas:info(?MODULE,"Social action", []),
    GameId = Msg#social_action.game,
    Res = #social_action_msg{type = Msg#social_action.type,
                             game = GameId,
                             recipient = Msg#social_action.recipient,
                             initiator = User#'PlayerInfo'.id},
    Participation = get_relay(GameId, Games),
    Ans = case Participation of
              false ->
                  {error, chat_not_registered};
              #participation{rel_pid = Srv, rel_module=RMod} ->
                  RMod:publish(Srv, Res)
          end,
    {reply, Ans, State};


handle_client_request(#subscribe_player_rels{players = Players}, _From,
            #state{user = User, rels_notif_channel = RelsChannel,
                   rels_players = RelsPlayers, rpc = RPC} = State) ->
    gas:info(?MODULE,"Subscribe player relations notifications: ~p", [Players]),
    UserId = User#'PlayerInfo'.id,
    UserIdStr = binary_to_list(UserId),
    %% Create subscription if we need
    NewRelsChannel =
        if RelsChannel == undefined ->
%               {ok, Channel} = nsx_msg:subscribe_for_user_actions(UserIdStr, self()),
%               Channel;
                RelsChannel;
           true ->
               RelsChannel
        end,
    %% Add players relations to which we need to common list
    F = fun(PlayerId, Acc) ->
                case lists:member(PlayerId, Acc) of
                    true -> Acc;
                    false -> [PlayerId | Acc]
                end
        end,
    NewRelsPlayers = lists:foldl(F, RelsPlayers, Players),

    %% Notify the client about current state of subscription relations.
    %% (Blocking relations state should be "false" at the start)
    F2 =
        fun(PlayerId) ->
                PlayerIdStr = binary_to_list(PlayerId),
                Type = case nsm_users:is_user_subscr(UserIdStr, PlayerIdStr) of
                           true -> ?SOCIAL_ACTION_SUBSCRIBE;
                           false -> ?SOCIAL_ACTION_UNSUBSCRIBE
                       end,
                Msg = #social_action_msg{initiator = UserId,
                                         recipient = PlayerId,
                                         type = Type},
                ok = send_message_to_player(RPC, Msg)
        end,
    lists:foreach(F2, Players),
    NewState = State#state{rels_players = NewRelsPlayers,
                           rels_notif_channel = NewRelsChannel},
    {reply, ok, NewState};


handle_client_request(#unsubscribe_player_rels{players = Players}, _From,
                      #state{rels_notif_channel = RelsChannel,
                             rels_players = RelsPlayers
                            } = State) ->
    gas:info(?MODULE,"Unsubscribe player relations notifications", []),
    %% Remove players from common list
    NewRelsPlayers = RelsPlayers -- Players,

    %% Remove subscription if we don't need it now
    NewRelsChannel =
        if NewRelsPlayers == [] -> nsm_mq_channel:close(RelsChannel),
               undefined;
           true ->
               RelsChannel
        end,
    NewState = State#state{rels_players = NewRelsPlayers,
                           rels_notif_channel = NewRelsChannel},
    {reply, ok, NewState};


handle_client_request(#join_game{game = GameId}, _From,
                      #state{user = User, rpc = RPC, games = Games} = State) ->
    UserId = User#'PlayerInfo'.id,
    gas:info(?MODULE,"Join game ~p user ~p from ~p", [GameId, UserId,_From]),
    case get_relay(GameId, Games) of
        #participation{} ->
            {reply, {error, already_joined}, State};
        false ->
            gas:info(?MODULE,"Requesting main relay info...",[]),
            case game_manager:get_relay_mod_pid(GameId) of
                {FLMod, FLPid} ->
                    gas:info(?MODULE,"Found the game: ~p. Trying to register...",[{FLMod, FLPid}]),
                    case FLMod:reg(FLPid, User) of
                        {ok, {RegNum, {RMod, RPid}, {TMod, TPid}}} ->
                            gas:info(?MODULE,"join to game relay: ~p",[{RMod, RPid}]),
                            {ok, _SubscrId} = RMod:subscribe(RPid, self(), UserId, RegNum),
                            Ref = erlang:monitor(process, RPid),
                            Part = #participation{ref = Ref, game_id = GameId, reg_num = RegNum,
                                                  rel_module = RMod, rel_pid = RPid,
                                                  tab_module = TMod, tab_pid = TPid, role = player},
                            Res = #'TableInfo'{}, % FIXME: The client should accept 'ok' responce
                            {reply, Res, State#state{games = [Part | State#state.games]}};
                        {error, finished} ->
                            gas:info(?MODULE,"The game is finished: ~p.",[GameId]),
                            ok = send_message_to_player(RPC, #disconnect{reason_id = <<"gameFinished">>,
                                                                         reason = null}),
                            {reply, {error, finished}, State};
                        {error, out} ->
                            gas:info(?MODULE,"Out of the game: ~p.",[GameId]),
                            ok = send_message_to_player(RPC, #disconnect{reason_id = <<"disconnected">>,
                                                                         reason = null}),
                            {reply, {error, out}, State};
                        {error, not_allowed} ->
                            gas:error(?MODULE,"Not allowed to connect: ~p.",[GameId]),
                            ok = send_message_to_player(RPC, #disconnect{reason_id = <<"notAllowed">>,
                                                                         reason = null}),
                            {reply, {error, not_allowed}, State}
                    end;
                undefined ->
                    gas:error(?MODULE,"Game not found: ~p.",[GameId]),
                    ok = send_message_to_player(RPC, #disconnect{reason_id = <<"notExists">>,
                                                                 reason = null}),
                    {reply, {error, not_exists}, State}
            end
    end;


handle_client_request(#game_action{game = GameId} = Msg, _From, State) ->
    gas:info(?MODULE,"Game action ~p", [{GameId,Msg,_From}]),
    Participation = get_relay(GameId, State#state.games),
    case Participation of
        false ->
            {reply, {error, game_not_found}, State};
        #participation{reg_num = RegNum, tab_pid = TPid, tab_module = TMod} ->
            UId = (State#state.user)#'PlayerInfo'.id,
            gas:info(?MODULE,"PLAYER ~p MOVES ~p in GAME ~p",[UId,Msg,GameId]),
            {reply, TMod:submit(TPid, RegNum, Msg), State}
    end;


handle_client_request(#pause_game{game = GameId, action = Action}, _From, State) ->

    Participation = get_relay(GameId, State#state.games),
    gas:info(?MODULE,"Pause game: ~p, user: ~p games: ~p",
        [GameId, State#state.user, State#state.games]),

    case Participation of
        false ->
            gas:info(?MODULE,"A", []),
            {reply, {error, game_not_found}, State};
        #participation{reg_num = RegNum, tab_pid = TPid, tab_module = TMod} ->
            Signal = case Action of
                         pause -> pause_game;
                         resume -> resume_game
                     end,
            Res = TMod:signal(TPid, RegNum, {Signal, self()}),
            gas:info(?MODULE,"B. Res: ~p", [Res]),
            {reply, Res, State}
    end;

handle_client_request(Request, _From, State) ->
    gas:info(?MODULE,"unrecognized client request: ~p", [Request]),
    {stop, {unknown_client_request, Request}, State}.

%%===================================================================

handle_relay_message(Msg, _SubscrId, #state{rpc = RPC} = State) ->
    try send_message_to_player(RPC, Msg) of
        ok -> {noreply, State};
        tcp_closed -> {stop, normal, State};
        E -> {stop, normal, State}
    catch exit:{normal, {gen_server,call, [RPC, {server, _}]}} -> {stop, normal, State};
          exit:{noproc, {gen_server,call, [RPC, {server, _}]}} -> {stop, normal, State};
          E:R -> {stop, normal, State} end.

%%===================================================================

%% The notification from the current table to rejoin to the game
%% because the user for example was moved to another table.
handle_relay_kick({rejoin, GameId}, _SubscrId,
                  #state{user = User, games = Games, rpc = RPC} = State) ->
    gas:info(?MODULE,"Requesting main relay info...",[]),
    UserId = User#'PlayerInfo'.id,
    case game_manager:get_relay_mod_pid(GameId) of
        {FLMod, FLPid} ->
            gas:info(?MODULE,"Found the game: ~p. Trying to register...",[{FLMod, FLPid}]),
            case FLMod:reg(FLPid, User) of
                {ok, {RegNum, {RMod, RPid}, {TMod, TPid}}} ->
                    gas:info(?MODULE,"Join to game relay: ~p",[{RMod, RPid}]),
                    {ok, _NewSubscrId} = RMod:subscribe(RPid, self(), UserId, RegNum),
                    Ref = erlang:monitor(process, RPid),
                    Part = #participation{ref = Ref, game_id = GameId, reg_num = RegNum,
                                          rel_module = RMod, rel_pid = RPid,
                                          tab_module = TMod, tab_pid = TPid, role = player},
                    NewGames = lists:keyreplace(GameId, #participation.game_id, Games, Part),
                    {noreply, State#state{games = NewGames}};
                {error, finished} ->
                    gas:info(?MODULE,"The game is finished: ~p.",[GameId]),
                    send_message_to_player(RPC, #disconnect{reason_id = <<"gameFinished">>,
                                                            reason = null}),
                    {stop, normal, State};
                {error, out} ->
                    gas:info(?MODULE,"Out of the game: ~p.",[GameId]),
                    send_message_to_player(RPC, #disconnect{reason_id = <<"kicked">>,
                                                            reason = null}),
                    {stop, normal, State};
                {error, not_allowed} ->
                    gas:error(?MODULE,"Not allowed to connect: ~p.",[GameId]),
                    send_message_to_player(RPC, #disconnect{reason_id = <<"notAllowed">>,
                                                            reason = null}),
                    {stop, {error, not_allowed_to_join}, State}
            end;
        undefined ->
            gas:error(?MODULE,"Game not found: ~p.",[GameId]),
            send_message_to_player(RPC, #disconnect{reason_id = <<"notExists">>,
                                                    reason = null}),
            {stop, {error, game_not_found}, State}
    end;

handle_relay_kick(Reason, _SubscrId, #state{rpc = RPC} = State) ->
    {ReasonId, ReasonText} =
        case Reason of
            table_closed -> {<<"tableClosed">>, null};
            table_down -> {null, <<"The table was closed unexpectedly.">>};
            game_over -> {null, <<"The game is over.">>};
            _ -> {<<"kicked">>, null}
        end,
    send_message_to_player(RPC, #disconnect{reason_id = ReasonId, reason = ReasonText}),
    {stop, normal, State}.

%%===================================================================

get_relay(GameId, GameList) ->
    lists:keyfind(GameId, #participation.game_id, GameList).

% TODO: flush message to web socket process

