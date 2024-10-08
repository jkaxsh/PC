-module(game_sim).
-include("server.hrl").
-export([start/1]).
-define(TICK_RATE, 16).
-include("pvectors.hrl").
-define(PLANET_RADIUS, 45).

start(Name) -> 
    GameProc = self(),
    ColProc = spawn(fun() -> check_pairs(GameProc) end),

    Chat = spawn(fun() -> gameChat(GameProc, #{}) end),
    PlanetsProc = spawn(fun() -> planets_manager(GameProc, #{}) end),

    gameSim(self(), Chat, PlanetsProc, ColProc, Name, maps:new(), false , 0, #{}). 

gameTick(GameProc) ->
    receive
        stop ->
            ok
        after
            ?TICK_RATE ->
                GameProc ! {tick},
                gameTick(GameProc)
    end.


gameChat(GameProc, OnChat) ->
    receive
        {new_message, Pid, Message} -> % sends message to all players
            ToSend = "chat@@@msg@@@" ++ maps:get(Pid, OnChat) ++ "@@@" ++ Message ++ "\n",
            lists:foreach(fun(Key) -> ?SEND_MESSAGE(Key, ToSend) end, maps:keys(OnChat)),
            gameChat(GameProc, OnChat);
        {pid_left, Pid} -> % removes a pid from the chat
            Username = maps:get(Pid, OnChat),
            NewOnChat = maps:remove(Pid, OnChat),
            ToSend = "chat@@@leave@@@" ++ Username ++ "@@@left chat\n",
            lists:foreach(fun(Key) -> ?SEND_MESSAGE(Key, ToSend) end, maps:keys(NewOnChat)),
            gameChat(GameProc, NewOnChat);
        {new_pid, Pid, Username} -> % adds a new pid to the chat
            gameChat(GameProc, maps:put(Pid, Username, OnChat))
    end.

afterGame(Chat, Name, Pids) ->
    receive
        {send_message, Pid, Message} -> % sends message to all players
            Chat ! {new_message, Pid, Message},
            afterGame(Chat, Name, Pids);
        {leave_chat, Pid} ->
            Chat ! {pid_left, Pid},
            ?SEND_MESSAGE(Pid, "game@@@end_game\n"),
            ?CHANGE_STATE(Pid, {end_game}),
            lobbyProc ! {leave, Name, Pid},
            NewPids = maps:remove(Pid, Pids),
            Keys = maps:keys(NewPids),
            if length(Keys) == 0 -> % if there are no players left
                finished;
            true ->
                afterGame(Chat, Name, NewPids)
            end
    end.

gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount, Indexes) ->
    receive
        {tick} -> % request and sends info of the current to all players
            lists:foreach(fun(Pid) ->
                case maps:get(Pid, Pids) of
                    {true, _, _} -> 
                        Pid ! {player_state};
                    _ ->
                        continue
                end
            end, maps:keys(Pids)),
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount, Indexes);
        {player_state, Pid, PlayerState, Index} -> % get player state
            {Alive, Username, _} = maps:get(Pid, Pids),
            NewPids = maps:put(Pid, {Alive,Username,PlayerState}, Pids),
            Indexes1 = maps:put(Pid, {Index, true}, Indexes),
            Bool = lists:all(fun({_, Value}) -> Value == true end, maps:values(Indexes1)),
            if Bool ->   % if all are marked as true <received>, check collisions and stuff
                AlivePredicate = fun(_Pid, {Living, _, _}) -> Living == true end,
                AlivePidStates = maps:filter(AlivePredicate, NewPids),
                Alives = length(maps:keys(AlivePidStates)),
                case Alives of
                    1 -> % last player alive
                        case Countdown of 
                            true -> % we don't need to check for player collisions anymore
                                PlanetsProc ! {tick, AlivePidStates}, 
                                Indexes2 = maps:fold(fun(_Pid, {_Index,_}, Acc) -> 
                                        maps:put(_Pid, {_Index, false}, Acc)
                                    end, Indexes1, Indexes1),
                                send_states(NewPids,Indexes2),
                                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerCount, Indexes2); % No changes, continue
                            _ ->
                                LastAlive = maps:keys(AlivePidStates),
                                LastAlive1 = lists:nth(1, LastAlive),

                                self() ! {start_end_game, LastAlive1},
                                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerCount, Indexes1)
                        end;                        
                    _ -> % more than one player alive
                        ColProc ! {check_pairs, AlivePidStates},
                        PlanetsProc ! {tick, AlivePidStates}, % send the new states to the planets manager
                        Indexes2 = maps:fold(fun(_Pid, {_Index,_}, Acc) -> 
                                maps:put(_Pid, {_Index, false}, Acc)
                            end, Indexes1, Indexes1),
                        receive 
                            {update, NewPidStates} ->
                                % Update states and send them to all players - collision manager only checked for alive players
                                UpdatePids = maps:fold(fun(Key, Value, Acc) -> 
                                    maps:put(Key, Value, Acc)
                                end, NewPids, NewPidStates),
                                lists:foreach(fun(Key) -> 
                                    KeyState = maps:get(Key, UpdatePids),
                                    {_,_,{U,B,{P,V,A,Angle},KM}} = KeyState,
                                    Key ! {updated_state, {U,B,{P,V,A,Angle},KM}}
                                end, maps:keys(UpdatePids)),
                                send_states(UpdatePids,Indexes2),  % Send the updated states to all players if there was a change
                                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, UpdatePids, Countdown, PlayerCount, Indexes2);
                            {ok} ->
                                send_states(NewPids, Indexes),       % Send the updated states to all players 
                                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerCount, Indexes2) % No changes, continue
                        end
                end;
            true ->
                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerCount, Indexes1)
            end;
        {starting_pos, Pid, StartingState,Index} -> % get player state
            {Alive, Username,_} = maps:get(Pid, Pids),
            NewPids = maps:put(Pid, {Alive, Username, StartingState}, Pids),
            NewIndexes = maps:put(Pid, {Index, false}, Indexes), 
            IndexLength = length(maps:keys(NewIndexes)),
            PidsLength = length(maps:keys(NewPids)),
            case IndexLength == PidsLength of
                true -> % all players have started
                    send_states(NewPids, NewIndexes),
                    KeyPids = maps:keys(NewPids),
                    PlanetsProc ! {launch_planets, KeyPids},                    
                    gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PidsLength, NewIndexes);
                false -> % not all players have started
                    gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerCount, NewIndexes)
            end;
        {countdown_started} ->
            lists:foreach(fun(Key) -> % sends to all players that last player countdown started
                ?SEND_MESSAGE(Key, "game@@@countdown_start\n")
            end, maps:keys(Pids)),
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, true, PlayerCount, Indexes);
        {countdown_ended} ->
            lists:foreach(fun(Key) -> % sends to all players that last player countdown ended
                ?SEND_MESSAGE(Key, "game@@@countdown_end\n")
            end, maps:keys(Pids)),
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, false, PlayerCount, Indexes);
        {new_pid, Username, Pid, PlayerNum} -> % add a new pid to the game     
            NewPids = maps:put(Pid, {true, Username, #{}}, Pids),
            Count = maps:size(NewPids),
            Pid ! {start_pos, Count},
            if Count == PlayerNum ->
                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, Countdown, PlayerNum, Indexes);
            true ->
                gameSim(Ticker, Chat, PlanetsProc, ColProc, Name,NewPids, Countdown, PlayerNum, Indexes)
            end;
        {go} -> 
            %% safety loading to make sure all players threads are running and gameStates have been updated
            %% also the loading screen should be displayed because it took effort to make it
            case PlayerCount of 
                0 -> 
                    GameProcMe = self(),
                    NTicker = spawn(fun() -> gameTick(GameProcMe) end),
                    gameSim(NTicker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount-1, Indexes);
                _ ->
                    ok
            end,
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount-1, Indexes);
        {send_message, Pid, Message} -> % sends message to all players
            Chat ! {new_message, Pid, Message},
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount, Indexes);
        {died, Pid} ->
            NewIndexes = maps:remove(Pid, Indexes),
            {_, Username,_} = maps:get(Pid, Pids),
            ?CHANGE_STATE(Pid, {died}),
            Chat ! {new_pid, Pid, Username},
            Chat ! {new_message, Pid, Username ++ " died\n"},
            {_, Username, _} = maps:get(Pid, Pids),
            lists:foreach(fun(Key) -> % sends to all players the pid that died
                String = "game@@@" ++ Username ++ "@@@died\n",
                ?SEND_MESSAGE(Key, String)
            end, maps:keys(Pids)),
            NewPids = maps:put(Pid, {false, Username, #{}}, Pids),
            Alives = maps:keys(NewIndexes),
            case length(Alives) of
                0 ->
                    self() ! {start_end_game, Pid},
                    gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, true, PlayerCount, NewIndexes); % se chegou aqui é porque o jogo ainda não tinha acabado quando morreu
                1 ->
                    GameProc = self(),
                    spawn(fun() -> countdown(GameProc) end),
                    gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, NewPids, true, PlayerCount, NewIndexes);
                _ ->
                    continue
            end;
        {start_end_game, LastAlive} -> 
            if Countdown -> % countdown still active - todos perdem, send lost to all por causa do xp para por a 0
                lists:foreach(fun(Pid) -> 
                    ?SEND_MESSAGE(Pid, "game@@@lost_game\n"),
                    ?CHANGE_STATE(Pid, {lost})
                end, maps:keys(Pids)),
                self() ! {interrupt_game, LastAlive},
                afterGame(Chat, Name, Pids);
            true -> % todos menos lastalive perdem
                Loop = maps:keys(Pids),
                ?SEND_MESSAGE(LastAlive, "game@@@won_game\n"),
                ?CHANGE_STATE(LastAlive, {won}),
                {_,Username,_} = maps:get(LastAlive, Pids),
                Chat ! {new_pid, LastAlive, Username},
                Loop_ = lists:delete(LastAlive, Loop),
                lists:foreach(fun(Pid) -> 
                            ?CHANGE_STATE(Pid, {lost}),
                            ?SEND_MESSAGE(Pid, "game@@@lost_game\n")
                    end, Loop_),
                self() ! {interrupt_game, LastAlive},
                afterGame(Chat, Name, Pids)
            end;
        {interrupt_game, RIP} -> % ends the game removing all pids
            NewIndexes = maps:remove(RIP, Indexes),
            NewIndexesLength = length(maps:keys(NewIndexes)),
            case NewIndexesLength of 
                0 ->
                    ColProc ! {stop_col},
                    PlanetsProc ! {quit_planets},
                    Ticker ! {stop};
                _ ->
                    afterGame(Chat, Name, maps:keys(Pids))
            end;
        Data ->
            io:format("Unexpected data ~p\n", [Data]),
            gameSim(Ticker, Chat, PlanetsProc, ColProc, Name, Pids, Countdown, PlayerCount, Indexes)
    end.

countdown(GameProc)-> 
    GameProc !  {countdown_started},
    timer:sleep(5000),
    GameProc !  {countdown_ended}.

send_states(States,Indexes) ->
    LoopStates = maps:keys(States),

    lists:foreach(fun(Key) -> 
        State = {Alive,_,_} = maps:get(Key, States),
        case Alive of
            true ->                        
                {_,Username,{_,Boost,{Pos,_,_,Angle},_}} = State,
                {Index,_} = maps:get(Key, Indexes),
                RelevantData = [Index,Username,Boost,Pos#pvector.x,Pos#pvector.y,Angle],
                FormattedData = io_lib:format("pos~w@@@~s@@@~w@@@~w@@@~w@@@~w\n", RelevantData),
                StringData = lists:flatten(FormattedData),
                lists:foreach(fun(Key2) ->
                    ?SEND_MESSAGE(Key2, StringData)
                end, LoopStates);
            _ ->
                ok
            end
    end, LoopStates).


        
check_pairs(CallerPid) ->
    receive 
        {check_pairs, PidStates} -> 
            % If there are less than 2 players left, there's no need for collision checks
            % {Alive , Username,                    PlayerState                                    ,KeyMap}
            % {Alive, Username, {UserAuth, 100, {{X,Y}, {VelX,VelY}, {AccelX,AccelY}, Angle}}, KeyMap}
            case length(maps:keys(PidStates)) of
                0 -> 
                    CallerPid ! {ok},
                    check_pairs(CallerPid);
                1 -> 
                    CallerPid ! {ok},
                    check_pairs(CallerPid);
                _ -> 
                    Pairs = generate_pairs(maps:keys(PidStates), []), % Generate pairs of Pids
                    UpdatedPids = lists:foldl(
                        fun({Pid1, Pid2}, Acc) ->
                            State1 = maps:get(Pid1, PidStates),
                            State2 = maps:get(Pid2, PidStates),
                            {P1, P2, S1, S2} = check_collisions(Pid1, Pid2, State1, State2),
                            Acc1 = maps:put(P1, S1, Acc),
                            Acc2 = maps:put(P2, S2, Acc1),
                            Acc2
                        end,
                        PidStates,
                        Pairs
                    ),
                    CallerPid ! {update, UpdatedPids},
                    check_pairs(CallerPid)
                end;
        {stop_col} ->
            ok
    end.



check_collisions(Pid1, Pid2, {Alive1,Username1,{UserAuth1, Boost1, {Pos1, Vel1, Accel1, Angle1}, KeyMap1}}, 
                             {Alive2,Username2,{UserAuth2, Boost2, {Pos2, Vel2, Accel2, Angle2}, KeyMap2}}) ->
    Distance = pvector_dist(Pos1, Pos2),
    case Distance < 50 of   %% 50 = player_radius * 2
        true ->
            Dx = Pos2#pvector.x - Pos1#pvector.x,
            Dy = Pos2#pvector.y - Pos1#pvector.y,
            Angle = pvector_heading(#pvector{x=Dx, y=Dy}),
            TargetX = Pos1#pvector.x + math:cos(Angle) * 50,
            TargetY = Pos1#pvector.y + math:sin(Angle) * 50,
            AX = (TargetX - Pos2#pvector.x),
            AY = (TargetY - Pos2#pvector.y),
            Vx = Vel1#pvector.x - AX,
            Vy = Vel1#pvector.y - AY,
            Vx2 = Vel2#pvector.x + AX,
            Vy2 = Vel2#pvector.y + AY,
            NewVel1 = #pvector{x=Vx,y=Vy},
            NewVel2 = #pvector{x=Vx2,y=Vy2};
        _ ->
            NewVel1 = Vel1,
            NewVel2 = Vel2
    end,
    State1 = {Alive1, Username1, {UserAuth1, Boost1, {Pos1, NewVel1, Accel1, Angle1}, KeyMap1}},
    State2 = {Alive2, Username2, {UserAuth2, Boost2, {Pos2, NewVel2, Accel2, Angle2}, KeyMap2}},
    {Pid1, Pid2, State1, State2}.



generate_pairs([], Acc) -> Acc;
generate_pairs([Pid | Rest], Acc) ->
    NewPairs = [{Pid, OtherPid} || OtherPid <- Rest],
    generate_pairs(Rest, Acc ++ NewPairs).



planets_manager(GameProc, PlanetStates) ->
    receive
        {launch_planets, PlayerPids} ->
            RandInt = rand:uniform(2), % 1 to 2
            PlanetCount = 2 + RandInt, % 3 to 4 planets in total
            StartPlanetStates = launch_planets(PlanetCount,PlanetStates),
            Loop2 = maps:keys(StartPlanetStates),
            lists:foreach(fun(Key) ->
                lists:foreach(fun(PlanetKey) ->
                    {Pos,Vel} = maps:get(PlanetKey, StartPlanetStates),
                    FormattedData = io_lib:format("p~w@@@~w@@@~w@@@~w@@@~w~n", [PlanetKey,Pos#pvector.x,Pos#pvector.y,Vel#pvector.x,Vel#pvector.y]),
                    StringData = lists:flatten(FormattedData),
                    ?SEND_MESSAGE(Key, StringData)
                end, Loop2)
            end, PlayerPids),
            % Send planet states to all players - confirm that the client can't simply emulate this from here on
            planets_manager(GameProc, StartPlanetStates);
        {tick, PlayerStates} ->
            PStates = maps:keys(PlayerStates),
            lists:foreach(fun(Key) ->
                {_,_,{_,_,{Pos,_,_,_},_}} = maps:get(Key, PlayerStates),
                Died = planet_collision(Pos, PlanetStates),
                case Died of
                    true ->
                        GameProc ! {died, Key};
                    _ ->
                        ok
                end
            end, PStates),
            % Check for collisions between players and planets
            % Inform gameProc that a player died if applicable
            self () ! {pre_calc, PlanetStates, PStates},
            planets_manager(GameProc, PlanetStates);
        {pre_calc, PlanetStates, Pids} ->
            % Pre-calculate the next planet states for the next frame 
            NextPlanetStates = getNextPlanetStates(PlanetStates),
            sendPlanetStates(PlanetStates, Pids),
            planets_manager(GameProc, NextPlanetStates);
        {quit_planets} ->
            ok
    end.


planet_collision(PlayerPos, PlanetStates) ->
    lists:any(fun({Pos, _}) -> 
        Distance = pvector_dist(PlayerPos, Pos),
        Distance < ?PLANET_RADIUS + 15  %% Planet radius + (player radius-5) -5 is for helping the player
    end, maps:values(PlanetStates)).

launch_planets(0, PlanetStates) -> 
    PlanetStates;
launch_planets(Count,PlanetStates) ->    
    SunPos = #pvector{x = 1980/2,y=1080/2},
    XorY = rand:uniform(),   % True for x, false for y  -> variable that decides if the planet will be on the x or y axis
    if XorY > 0.5 ->     % Planet will be positioned horizontally
        LeftOrRight = rand:uniform(), % True for left, false for right
        if LeftOrRight > 0.5 -> % Planet will be positioned on the left
            X = random_between(-400, SunPos#pvector.x - 400),
            Location = #pvector{x=X,y=SunPos#pvector.y},
            VY = random_between(-4, -9),
            Vel = #pvector{x=0,y=VY};
        true -> % Planet will be positioned on the right
            X = random_between(SunPos#pvector.x + 400, 1920 + 400),
            Location = #pvector{x=X,y=SunPos#pvector.y},
            VY = random_between(-4, -9),
            Vel = #pvector{x=0,y=VY}
        end;
    true -> % Planet will be positioned vertically
        UpOrDown = rand:uniform(), % True for up, false for down
        if UpOrDown > 0.5 -> % Planet will be positioned on the top
            Y = random_between(-400, SunPos#pvector.y - 400),
            Location = #pvector{x=1920/2,y=Y},
            VX = random_between(-4, -9),
            Vel = #pvector{x=VX,y=0};
        true -> % Planet will be positioned on the bottom
            Y = random_between(SunPos#pvector.y + 400, 1080 + 400),
            Location = #pvector{x=1920/2,y=Y},
            VX = random_between(-4, -9),
            Vel = #pvector{x=VX,y=0}            
        end
    end,
    NewPlanetStates = maps:put(Count, {Location, Vel}, PlanetStates),
    launch_planets(Count - 1, NewPlanetStates).

% Helper function for generating random numbers in a range
random_between(Min, Max) ->
    Min + trunc(rand:uniform() * (Max - Min + 1)) - 1.


getNextPlanetStates(PlanetStates) ->
    NewPlanetStates = 
        lists:foldl(
        fun(Key, Acc) ->
            Planet = maps:get(Key, PlanetStates),
            NewPlanet = nextPlanetPos(Planet),
            maps:put(Key, NewPlanet, Acc)
        end,
        PlanetStates,
        maps:keys(PlanetStates)
    ),
    NewPlanetStates.

nextPlanetPos({Pos, Vel}) -> %% TODO - ADJUST VALUES MAGNITUDE AND VELOCITY LIMIT
    SunPos = #pvector{x = 1980/2,y=1080/2},
    Accel = pvector_sub(SunPos, Pos), % Get the vector from the player to the sun
    Accel1 = set_magnitude(Accel, 0.04), %% TODO - Change the magnitude after testing, planet should be floating more
    NewVel = pvector_add(Vel, Accel1),
    NewLimitedVel = pvector_limit(NewVel, 5),
    NewPos = pvector_add(Pos, NewLimitedVel),
    {NewPos, NewLimitedVel}.


sendPlanetStates(Planets, Pids) ->
    lists:foreach(fun(Key) ->
        {Pos,Vel} = maps:get(Key, Planets),
        FormattedData = io_lib:format("p~w@@@~w@@@~w@@@~w@@@~w~n", [Key,Pos#pvector.x,Pos#pvector.y,Vel#pvector.x,Vel#pvector.y]),
        StringData = lists:flatten(FormattedData),
        lists:foreach(fun(Pid) ->
            ?SEND_MESSAGE(Pid, StringData)
        end, Pids)
    end, maps:keys(Planets)).
    