-record(user, {username, password}).
-record(message, {type, from, text}).

-define(CREATE_ACCOUNT, "1").
-define(LOGIN_ACCOUNT, "2").
-define(LOGOUT_ACCOUNT, "3").
-define(JOIN_ROOM, "4").
-define(LEAVE_ROOM, "5").