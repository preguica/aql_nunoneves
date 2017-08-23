%% @author Joao
%% @doc @todo Add description to select.


-module(select).

-include_lib("parser.hrl").
-include_lib("aql.hrl").

%% ====================================================================
%% API functions
%% ====================================================================
-export([exec/3]).

-export([table/1,
				projection/1,
				where/1]).

exec({Table, _Tables}, Select, TxId) ->
	TName = table:name(Table),
	Cols = table:columns(Table),
	Projection = projection(Select),
	% TODO validate projection fields
	Condition = where(Select),
	Keys = where:scan(TName, Condition, TxId),
	case Keys of
		[] -> {ok, []};
		_Else ->
			{ok, Results} = antidote:read_objects(Keys, TxId),
			ProjectionResult = project(Projection, Results, [], Cols),
			ActualRes = apply_offset(ProjectionResult, Cols, []),
			{ok, ActualRes}
	end.

table({TName, _Projection, _Where}) -> TName.

projection({_TName, Projection, _Where}) -> Projection.

where({_TName, _Projection, Where}) -> Where.

%% ====================================================================
%% Private functions
%% ====================================================================

apply_offset([[{{'#st', _T}, _V}] | Results], Cols, Acc) ->
	apply_offset(Results, Cols, Acc);
apply_offset([Result | Results], Cols, Acc) when is_list(Result) ->
	Result1 = apply_offset(Result, Cols, []),
	apply_offset(Results, Cols, Acc ++ [Result1]);
apply_offset([{{'#st', _T}, _} | Values], Cols, Acc) ->
	apply_offset(Values, Cols, Acc);
apply_offset([{{Key, Type}, V} | Values], Cols, Acc) ->
  Col = maps:get(Key, Cols),
  Cons = column:constraint(Col),
	case {Type, Cons} of
    {?AQL_COUNTER_INT, ?CHECK_KEY({?COMPARATOR_KEY(Comp), Offset})} ->
			AQLCounterValue = bcounter:from_bcounter(Comp, V, Offset),
			NewAcc = lists:append(Acc, [{Key, AQLCounterValue}]),
      apply_offset(Values, Cols, NewAcc);
    _Else ->
			NewAcc = lists:append(Acc, [{Key, V}]),
			apply_offset(Values, Cols, NewAcc)
  end;
apply_offset([], _Cols, Acc) -> Acc.

project(Projection, [[] | Results], Acc, Cols) ->
	project(Projection, Results, Acc, Cols);
project(Projection, [Result | Results], Acc, Cols) ->
	ProjRes = project_row(Projection, Result, [], Cols),
	project(Projection, Results, Acc ++ [ProjRes], Cols);
project(_Projection, [], Acc, _Cols) ->
	Acc.

project_row(?PARSER_WILDCARD, Result, _Acc, _Cols) ->
	Result;
project_row([ColName | Tail], Result, Acc, Cols) ->
	{{Key, _Type}, Value} = get_value(ColName, Result),
	Col = column:s_get(Cols, Key),
	Type = column:type(Col),
	NewResult = proplists:delete(ColName, Result),
	NewAcc = Acc ++ [{{Key, Type}, Value}],
	project_row(Tail, NewResult, NewAcc, Cols);
project_row([], _Result, Acc, _Cols) ->
	Acc.

get_value(Key, [{{Name, _Type}, _Value} = H| T]) ->
	case Key of
		Name ->
			H;
		_Else ->
			get_value(Key, T)
	end;
get_value(_Key, []) ->
	undefined.
