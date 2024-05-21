-module(lobby).
-include("server.hrl").
-export[start/0].

start() -> lobby(#{}).
% gestor de salas do jogo
lobby(Rooms) ->
    receive
        {countdown_started, Room}  ->
            io:fwrite("Countdown\n"),
            {_, Pids} = maps:get(Room, Rooms),
            lists:foreach(fun(Pid) -> ?SEND_MESSAGE(Pid, "countdown_started\n") end, Pids),
            lobby(Rooms);
        {start_game, Room, Game}  ->
            {_, Pids} = maps:get(Room, Rooms),
            lists:foreach(fun(Pid) -> Pid ! {start_game, Game}, ?SEND_MESSAGE(Pid, "enter_game\n"), ?CHANGE_STATE(Pid, {send_pid}) end, Pids),
            maps:remove(Room, Rooms),
            lobby(Rooms);
        {join, User, Lobby, Room, Level, Pid} -> % jogador tenta entrar numa sala
            if Lobby == "main" ->
                if User == "Anonymous" ->
                    ?SEND_MESSAGE(Pid, "Precisas de fazer login\n"),
                    lobby(Rooms);
                true ->
                    case maps:is_key(Room, Rooms) of
                        true ->
                            {RLevel, Pids} = maps:get(Room, Rooms),
                            if Level == RLevel orelse Level == RLevel + 1 orelse Level == RLevel - 1 -> % nivel de dificuldade
                                if length(Pids) < 4 -> % maximo de jogadores
                                    NRooms = maps:put(Room, {RLevel, [Pid | Pids]} , Rooms),
                                    ?CHANGE_STATE(Pid, {new_room, Room}),
                                    ?SEND_MESSAGE(Pid, "success\n"),
                                    if (length(Pids) + 1) == 2 -> %% start countdown
                                        ?CHANGE_STATE(Pid, {countdown, Room}); 
                                    true ->
                                        ?CHANGE_STATE(Pid, {wait}) % espera para comecar o jogo
                                    end,
                                    lobby(NRooms);
                                true ->
                                    ?SEND_MESSAGE(Pid, "Sala cheia\n"),
                                    lobby(Rooms)
                                end;
                            true ->
                                ?SEND_MESSAGE(Pid, "Nivel diferente da sala\n"),
                                lobby(Rooms)
                            end;
                        false ->
                            ?SEND_MESSAGE(Pid, "Sala nao existe\n"),
                            lobby(Rooms)
                    end
                end;
            true ->
                ?SEND_MESSAGE(Pid, "Ja estas noutra sala, sai primeiro\n"),
                lobby(Rooms)
            end;
        {create_room, Room, Level, Pid} -> % jogador tenta criar sala
            case maps:is_key(Room, Rooms) of
                true ->
                    ?SEND_MESSAGE(Pid, "Esta sala ja existe\n"),
                    lobby(Rooms);
                false ->
                    ?SEND_MESSAGE(Pid, "success\n"),
                    NRooms = maps:put(Room, {Level, []}, Rooms),
                    lobby(NRooms)
            end;
        {list_rooms, Level, Pid} -> % lista as salas ao jogador
            Ver = fun(Key, Value, Acc) -> 
                {RLevel, _} = Value,
                if Level == RLevel orelse Level == RLevel + 1 orelse Level == RLevel - 1 ->
                    [Key | Acc];
                true ->
                    Acc
                end
            end,
            RoomsList = maps:fold(Ver, [], Rooms),
            ?SEND_MUL_MESSAGE(Pid, RoomsList),
            lobby(Rooms);
        {leave, Room, Pid} -> % jogador tenta sair da sala, se estiver numa
            if Room == "main" ->
                ?SEND_MESSAGE(Pid, "Nao estas em nenhuma sala\n"),
                lobby(Rooms);
            true->
                {Level, Pids} = maps:get(Room, Rooms),
                if length(Pids) =< 1 ->
                    NRooms = maps:remove(Room, Rooms);
                true ->
                    NRooms = maps:put(Room, {Level, lists:delete(Pid, Pids)}, Rooms)
                end,
                ?SEND_MESSAGE(Pid, "success\n"),
                ?CHANGE_STATE(Pid, {new_room, "main"}),
                ?CHANGE_STATE(Pid, {leave}), %% start game
                lobby(NRooms)
            end;
        {offline, Room, Pid} -> % jogador e eliminado das salas caso saia inesperadamente
            self() ! {leave, Room, Pid},
            lobby(Rooms)
    end.