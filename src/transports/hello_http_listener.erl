% Copyright (c) 2010-2011 by Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

% @private
-module(hello_http_listener).

-behaviour(hello_listener).
-export([listener_specification/2, send_response/2, close/1, listener_termination/2, port/2]).

%% cowboy http handler callbacks
-export([init/3, handle/2, terminate/3]).

-include("hello.hrl").
-include_lib("ex_uri/include/ex_uri.hrl").

-record(http_listener_state, {
    url     :: #ex_uri{}
}).

%% --------------------------------------------------------------------------------
%% -- hello_binding callbacks
listener_specification(ExUriUrl, _TransportOpts) ->
    % cowboy dispatch
    State = #http_listener_state{ url = ExUriUrl },
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, [State]}]}]),
    %% Copied from cowboy.erl because it doesn't provide an API that
    %% allows supervising the listener from the calling application yet.
    Acceptors = 30,
    {IP, _Host} = extract_ip_and_host(ExUriUrl),
    Port = (ExUriUrl#ex_uri.authority)#ex_uri_authority.port,
    TransportOpts = [{port, Port}, {ip, IP}],
    ProtocolOpts = [{env, [{dispatch, Dispatch}]}],
    Result = cowboy:start_http({?MODULE, ExUriUrl}, Acceptors, TransportOpts, ProtocolOpts),
    {other_supervisor, Result}.

send_response(#context{transport_pid = TPid, transport_params = TParams, peer = Peer}, BinResp) ->
    TPid ! {hello_msg, TParams, Peer, BinResp}.

close(#context{transport_pid = TPid}) ->
    TPid ! hello_closed.

listener_termination(ExUriUrl, _ListenerRef) ->
    ranch:stop_listener({?MODULE, ExUriUrl}).

port(_, _) ->
    error(badarg, not_supported).
%% --------------------------------------------------------------------------------
%% -- request handling (callbacks for cowboy_http_handler)
init({tcp, http}, Req, [State]) ->
    {ok, Req, State}.

handle(Req, State = #http_listener_state{url = URL}) ->
    {Method, Req1} = cowboy_req:method(Req),
    case lists:member(Method, [<<"PUT">>, <<"POST">>]) of
        true ->
            {TransportParams, Req2} = req_transport_params(Req1),
            {Peer, Req3} = cowboy_req:peer(Req2),
            {ok, Message, Req4} = cowboy_req:body(Req3),
            Context = #context{ transport = ?MODULE,
                                transport_pid = self(),
                                transport_params = TransportParams,
                                peer = Peer},
            hello_listener:async_incoming_message(Context, URL, Message),
            CompactReq = cowboy_req:compact(Req4),
            {ok, Req5} = cowboy_req:chunked_reply(200, response_header(<<"TODO:ContentType">>), CompactReq),
            http_chunked_loop(Req5, State);
        false ->
            {ok, Req2} = cowboy_req:reply(405, server_header(), Req1),
            {ok, Req2, State}
    end.

http_chunked_loop(Req, State) ->
    receive
        hello_closed ->
            {ok, Req, State};
        {hello_msg, _TParams, _Peer, BinResp} ->
            ok = cowboy_req:chunk(BinResp, Req),
            http_chunked_loop(Req, State)
    end.

terminate(_Reason, _Req, _State) ->
    ok.

%% helpers
response_header(ContentType) ->
    [{<<"Content-Type">>, ContentType}] ++ server_header().

server_header() ->
    {ok, Vsn} = application:get_key(hello, vsn),
    [{<<"Server">>, erlang:list_to_binary("hello/" ++ Vsn)}].

req_transport_params(Req1) ->
    {{PeerIP, PeerPort}, Req2} = cowboy_req:peer(Req1),
    {ProxyPeerIP, Req3} = peer_addr(Req2),
    {QSVals, Req4} = cowboy_req:qs_vals(Req3),
    {Cookies, Req5} = cowboy_req:cookies(Req4),
    TransportParams = [{peer_ip, PeerIP},
                       {peer_port, PeerPort},
                       {real_peer_ip, ProxyPeerIP},
                       {query_params, QSVals},
                       {cookie_params, Cookies}],
    {TransportParams, Req5}.

peer_addr(Req) ->
    {RealIp, Req1} = cowboy_req:header(<<"X-Real-Ip">>, Req),
    {ForwardedForRaw, Req2} = cowboy_req:header(<<"X-Forwarded-For">>, Req1),
    {{PeerIp, _PeerPort}, Req3} = cowboy_req:peer(Req2),
    ForwardedFor = case ForwardedForRaw of
        undefined ->
            undefined;
        ForwardedForRaw ->
            case re:run(ForwardedForRaw, "^(?<first_ip>[^\\,]+)",
                    [{capture, [first_ip], binary}]) of
                {match, [FirstIp]} -> FirstIp;
                _Any -> undefined
            end
    end,
    {ok, PeerAddr} = if
        is_binary(RealIp) -> inet_parse:address(binary_to_list(RealIp));
        is_binary(ForwardedFor) -> inet_parse:address(binary_to_list(ForwardedFor));
        true -> {ok, PeerIp}
    end,
    {PeerAddr, Req3}.

extract_ip_and_host(#ex_uri{authority = #ex_uri_authority{host = Host}}) ->
     case Host of
        "*"  ->
            {{0,0,0,0}, "0.0.0.0"};
        Host ->
            case inet_parse:address(Host) of
                {error, einval} ->
                    {{0,0,0,0}, Host};
                {ok, Address} ->
                    {Address, Host}
            end
    end.
