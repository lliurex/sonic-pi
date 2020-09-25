-module(osc).
%% --
%% This file is part of Sonic Pi: http://sonic-pi.net
%% Full project source: https://github.com/samaaron/sonic-pi
%% License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
%%
%% Copyright 2016,2017 by Joe Armstrong (http://joearms.github.io/)
%% All rights reserved.
%%
%% Permission is granted for use, copying, modification, and
%% distribution of modified versions of this work as long as this
%% notice is included.
%% ++

-compile(export_all).

%% Note: not all tags are implemented yet
%%       note super well tested - appears to work :-)

%%----------------------------------------------------------------------
%% Encoding
%%----------------------------------------------------------------------

%% Do do check endian
%% I've said Int64 are unsigned-little-integers
%% I think they should be big

%% The OSC spec is unclear about this point

%% To do check endianness carefully
%% To do add device number

test0() ->
    B = encode(["/mi",{int64, 347873045749854},145,53,0]),
    io:format("B=~p~n",[B]),
    D = (catch decode(B)),
    io:format("D=~p~n",[D]).

test1() ->
    decode(<<35,98,117,110,100,108,101,0,218,114,254,188,137,88,216,0,0,0,0,16,
           47,102,111,111,0,0,0,0,44,115,0,0,98,97,114,0>>).

test2() ->
    pack_ts(osc:now() + 10,
	    ["/forward", "localhost", 6000, "/sendmidi", 12, 34, 56]).

test3() ->
    %% Precondition - pi_server:start().
    PiPort = 8014,
    FwPort = 6000,
    true = lists:member(pi_server, registered()) orelse
        pi_server:start([list_to_atom(integer_to_list(PiPort))]),
    SendLater = ["/sendmidi", 12, 34, 56],
    EncodedLater = encode(SendLater),
    {ok, Socket} = gen_udp:open(FwPort, [binary, {ip, loopback}]),
    Time1 = osc:now(),
    gen_udp:send(Socket, localhost, PiPort,
                 pack_ts(Time1 + 10,
                         ["/send_after", "localhost", FwPort | SendLater])),
    Result =
        receive
            {udp, Socket, {127,0,0,1}, PiPort, EncodedLater} ->
                Time2 = osc:now(),
                DT = Time2 - Time1,
                io:format("Got back message ~p after ~f s~n",
                          [decode(EncodedLater), DT]),
                if
                    DT > 10.002 orelse DT < 9.998 ->
                        io:format("Message not within 2ms margin~n"),
                        nok;
                    true ->
                        ok
                end
        after 11000 ->
                io:format("Timeout waiting for response~n"),
                nok
        end,

    gen_udp:close(Socket),
    Result.

%% osc:now() returns the system time as a float
%% The units of the timestamp are seconds past epoch

now() ->
    %% nanoseconds past epoc
    erlang:system_time(nanosecond)/1000000000.

osc_time_to_local(Tsec) ->
    Native = trunc(Tsec*1000000000), %% 9 zeros
    Nano = erlang:convert_time_unit(Native, native, micro_seconds),
    S = Nano div 1000000000, %% 9 zeros
    %% the three args below are MegaSec Sec MicroSec
    Micro = Nano rem 1000000, %%6
    Time = calendar:now_to_local_time({S div 1000000000,
				       S rem 1000000000,
				       Micro}),
    Frac = Micro/1000000,
    %% Umm not totally convinced of this ...
    {Time, Frac}.

encode([Verb|Args]) ->
    %% io:format(Verb),
    %% io:format(Args),
    %% io:format("===="),
    Str   = encode_string(Verb),
    Flags = encode_flags(Args),
    Data  = [encode_arg(I) || I <- Args],
    list_to_binary([Str,Flags,Data]).

encode_string(S) ->
    %% zero terminate S and pad to 4 byte boundary
    case length(S) rem 4 of
	0 -> [S,0,0,0,0];
	1 -> [S,0,0,0];
	2 -> [S,0,0];
	3 -> [S,0]
    end.

encode_flags(L) when is_list(L) ->
    %% flags starts with , and is terminated with a zero
    %% so it's really a string :-)
    L1 = [encode_flag(I) || I <- L],
    encode_string([$,|L1]).

encode_flag({int64,_})            -> $h;
encode_flag({time,_})             -> $t;
encode_flag(I) when is_integer(I) -> $i;
encode_flag(X) when is_list(X)    -> $s;
encode_flag(X) when is_atom(X)    -> $s;
encode_flag(X) when is_float(X)   -> $f.

encode_arg(X) when is_list(X)    -> encode_string(X);
encode_arg(X) when is_atom(X)    -> encode_string(atom_to_list(X));
encode_arg(X) when is_integer(X) -> <<X:32>>;
encode_arg(X) when is_float(X)   -> <<X:32/float>>; %
encode_arg({int64,X})            -> <<X:64/unsigned-little-integer>>.

%% bundles

pack_ts(Time, Data) ->
    %% io:format("Pack ts:~p ~p~n", [Time, Data]),
    %% Time is an NTP timestamp
    BTime = encode_time(Time),
    BData = encode(Data),
    Size = size(BData),
    B = <<"#bundle",0,BTime/binary,Size:32,BData/binary>>,
    %% uppack just to check
    %% {bundle,T1,[{_,B1}]} = decode(B),
    %% E1 = decode(B1),
    %% io:format("decoded:~p ~p~n",[T1,E1]),
    B.

%%----------------------------------------------------------------------
%5 Decoding
%%----------------------------------------------------------------------

decode(B0) when is_binary(B0) ->
    {Verb,  B1}      = get_string(B0),
    %% io:format("Verb: ~p~n",[Verb]),
    case Verb of
	"#bundle" ->
	    <<Time:8/binary, B2/binary>> = B1,
	    {bundle, decode_time(Time), decode_bundle(B2)};
	_ ->
	    {[$,|Flags], B2} = get_string(B1),
	    %% io:format("Verb: ~p Flags:~p~n",[Verb,Flags]),
	    {cmd, [Verb|get_args(Flags, B2, [])]}
    end.

-define(EPOCH,	  	2208988800).		% offset yr 1900 to unix epoch

%% encode_time(Time)
%%   Time is inlocal units - for example
%%   Time = osc:now() + 10.0  means (in 10 seconds time)

encode_time(Time) ->
    T1 = Time + ?EPOCH,
    IntPart = trunc(T1),
    F = T1 - IntPart,
    FracPart = trunc(F * (2 bsl 31)),
    <<IntPart:32, FracPart:32/unsigned-big-integer>>.

decode_time(<<X:32,Y:32/unsigned-big-integer>>) ->
    X - ?EPOCH + binfrac(Y).

%% binfrac(Bin) -> binfrac(Bin, 2, 0).
%% binfrac(0, _, Frac) -> Frac;
%% binfrac(Bin, N, Frac) -> binfrac(Bin bsr 1, N*2, Frac + (Bin band 1)/N).

binfrac(I) -> I / (2 bsl 31).


decode_bundle(<<Size:32,B:Size/binary,B1/binary>>) ->
    [{Size, B}|decode_bundle(B1)];
decode_bundle(<<>>) ->
    [].

get_args([$i|T1], <<I:32/signed-integer,T2/binary>>, L) ->
    get_args(T1, T2, [I|L]);
get_args([$f|T1], <<F:32/float, T2/binary>>, L) ->
    get_args(T1, T2, [F|L]);
get_args([$h|T1], <<I:64/unsigned-little-integer, T2/binary>>, L) ->
    get_args(T1, T2, [{int64,I}|L]);
get_args([$d|T1], <<Double:64/float, T2/binary>>, L) ->
    get_args(T1, T2, [Double|L]);
get_args([$s|T1], B0, L) ->
    {Str, B1} = get_string(B0),
    get_args(T1, B1, [Str|L]);
get_args([], _, L) ->
    lists:reverse(L).

get_string(X) when is_binary(X) ->
    [Bin,After] = binary:split(X, <<0>>),
    %% skip to bounday
    K = 3 - (size(Bin) rem 4),
    {binary_to_list(Bin), skip(K, After)}.

skip(0, B) -> B;
skip(N, B) -> element(2, erlang:split_binary(B, N)).
