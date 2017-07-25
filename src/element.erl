
-module(element).

-define(DATA_ENTRY(Key, Crdt), {Key, Crdt}).
-define(CRDT_TYPE, antidote_crdt_gmap).
-define(EL_KEY, '#key').
-define(EL_COLS, '#cols').
-define(EL_PK, '#pk').
-define(EL_FK, '#fl').
-define(EL_ST, ?DATA_ENTRY('#st', antidote_crdt_mvreg)).
-define(EL_ANON, none).

-include("aql.hrl").
-include("parser.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([primary_key/1, foreign_keys/1, attributes/1,]).

-export([create_key/2, st_key/0, st_value/1]).

-export([new/1, new/2,
        put/3, get/3,
        insert/1, insert/2]).

%% ====================================================================
%% Property functions
%% ====================================================================

primary_key(Element) ->
  dict:fetch(?EL_KEY, Element).

foreign_keys(Element) ->
  dict:fetch(?EL_FK, Element).

attributes(Element) ->
  dict:fetch(?EL_COLS, Element).

%% ====================================================================
%% Utils functions
%% ====================================================================

create_key(Key, TName) ->
  crdt:create_bound_object(Key, ?CRDT_TYPE, TName).

st_key() ->
  ?EL_ST.

st_value(Values) ->
  Value = proplists:get_value(?EL_ST, Values),
  ipa:status(ipa:add_wins(), Value).

throwInvalidType(Type, CollumnName) ->
	throw(lists:concat(["Invalid type ", Type, " for collumn: ", CollumnName])).

throwNoSuchColumn(ColName) ->
  throw(lists:concat(["Column ", ColName, " does not exist."])).

%% ====================================================================
%% API functions
%% ====================================================================

new(Table) when ?is_table(Table) ->
  new(?EL_ANON, Table).

new(Key, Table) when ?is_dbkey(Key) and ?is_table(Table) ->
  Bucket = table:name(Table),
  BoundObject = create_key(Key, Bucket),
  Columns = table:get_columns(Table),
  PrimaryKey = table:primary_key(Table),
  El0 = dict:new(),
  El1 = dict:store(?EL_KEY, BoundObject, El0),
  El2 = dict:store(?EL_COLS, Columns, El1),
  El3 = dict:store(?EL_PK, PrimaryKey, El2),
  El4 = dict:store(?EL_ST, crdt:assign_lww(ipa:new()), El3),
  El5 = dict:store(?EL_FK, [], El4),
  load_defaults(dict:to_list(Columns), El5).

load_defaults([{CName, Column}|Columns], Element) ->
  Constraint = column:constraint(Column),
  case Constraint of
    {?DEFAULT_TOKEN, Value} ->
      NewEl = append(CName, Value, column:type(Column), Element),
      load_defaults(Columns, NewEl);
    _Else ->
      load_defaults(Columns, Element)
  end;
load_defaults([], Element) ->
  Element.

put([Key | OKeys], [Value | OValues], Element) ->
  %check if Keys and Values have the same size
  Res = put(Key, Value, Element),
  case Res of
    {err, _Msg} ->
      Res;
    _Else ->
      put(OKeys, OValues, Res)
  end;
put([], [], Element) ->
  {ok, Element};
put(?PARSER_ATOM(ColName), Value, Element) when ?is_cname(ColName) ->
  Res = dict:find(ColName, attributes(Element)),
  case Res of
    {ok, Col} ->
      ColType = column:type(Col),
      Element1 = handle_fk(Col, Value, Element),
      Element2 = set_if_primary(Col, Value, Element1),
      append(ColName, Value, ColType, Element2);
    _Else ->
      throwNoSuchColumn(ColName)
  end.

set_if_primary(Col, Value, Element) ->
  case column:is_primarykey(Col) of
    true ->
      set_key(Value, Element);
    _Else ->
      Element
  end.

set_key(?PARSER_TYPE(_Type, Value), Element) ->
  {_Key, Type, Bucket} = dict:fetch(?EL_KEY, Element),
  dict:store(?EL_KEY, crdt:create_bound_object(Value, Type, Bucket), Element).

handle_fk(Col, ?PARSER_TYPE(_Type, Value), Element) ->
  CName = column:name(Col),
  Constraint = column:constraint(Col),
  case Constraint of
    ?FOREIGN_KEY({?PARSER_ATOM(Table), _Attr}) ->
      dict:append(?EL_FK, {CName, {Value, Table}}, Element);
    _Else ->
      Element
  end.

get(ColName, Crdt, Element) when ?is_cname(ColName) ->
  Res = dict:find(?DATA_ENTRY(ColName, Crdt), Element),
  case Res of
    {ok, Value} ->
      Value;
    _Else ->
      throwNoSuchColumn(ColName)
  end.

insert(Element) ->
  DataMap = dict:filter(fun is_data_field/2, Element),
  Ops = dict:to_list(DataMap),
  Key = primary_key(Element),
  crdt:map_update(Key, Ops).
insert(Element, TxId) ->
  Op = insert(Element),
  antidote:update_objects(Op, TxId).

is_data_field(?EL_KEY, _V) -> false;
is_data_field(?EL_PK, _V) -> false;
is_data_field(?EL_COLS, _V) -> false;
is_data_field(?EL_FK, _V) -> false;
is_data_field(_Key, _V) -> true.

append(Key, WrappedValue, AQL, Element) ->
  Token = types:to_parser(AQL),
  if
    ?is_parser_type(WrappedValue, Token) ->
      ?PARSER_TYPE(_Type, Value) = WrappedValue,
      OffValue = apply_offset(Key, Value, Element),
      OpVal = types:to_insert_op(AQL, OffValue),
      dict:store(?DATA_ENTRY(Key, types:to_crdt(AQL)), OpVal, Element);
    ?is_parser(WrappedValue) ->
      ?PARSER_TYPE(Type, _Value) = WrappedValue,
      throwInvalidType(Type, Key)
  end.

apply_offset(Key, Value, Element) ->
  Col = dict:fetch(Key, attributes(Element)),
  Type = column:type(Col),
  Cons = column:constraint(Col),
  case {Type, Cons} of
    {?AQL_COUNTER_INT, {?COMPARATOR_KEY(Comp), ?PARSER_NUMBER(Offset)}} ->
      bcounter:to_bcounter(Key, Value, Offset, Comp);
    _Else -> Value
  end.

%%====================================================================
%% Eunit tests
%%====================================================================

-ifdef(TEST).

create_table_aux() ->
  {ok, Tokens, _} = scanner:string("CREATE LWW TABLE Universities (WorldRank INT PRIMARY KEY, InstitutionId VARCHAR FOREIGN KEY REFERENCES Institution(id), NationalRank INTEGER DEFAULT 1);"),
	{ok, [{?CREATE_TOKEN, Table}]} = parser:parse(Tokens),
  Table.

primary_key_test() ->
  Table = create_table_aux(),
  Element = new(key, Table),
  ?assertEqual(create_key(key, 'Universities'), primary_key(Element)).

attributes_test() ->
  Table = create_table_aux(),
  Columns = table:get_columns(Table),
  Element = new(key, Table),
  ?assertEqual(Columns, attributes(Element)).

key_test() ->
  Key = key,
  TName = test,
  Expected = crdt:create_bound_object(Key, ?CRDT_TYPE, TName),
  ?assertEqual(Expected, create_key(Key, TName)).

new_test() ->
  Key = key,
  Table = create_table_aux(),
  BoundObject = create_key(Key, table:name(Table)),
  Columns = table:get_columns(Table),
  Pk = table:primary_key(Table),
  AnnElWithCols = dict:store(?EL_COLS, Columns, dict:new()),
  Data = dict:to_list(load_defaults(dict:to_list(Columns), AnnElWithCols)),
  Element = new(Key, Table),
  ?assertEqual(6, dict:size(Element)),
  ?assertEqual(BoundObject, dict:fetch(?EL_KEY, Element)),
  ?assertEqual(Columns, dict:fetch(?EL_COLS, Element)),
  ?assertEqual(Pk, dict:fetch(?EL_PK, Element)),
  ?assertEqual(crdt:assign_lww(ipa:new()), dict:fetch(?EL_ST, Element)),
  ?assertEqual([], dict:fetch(?EL_FK, Element)),
  AssertPred = fun ({K, V}) -> ?assertEqual(V, dict:fetch(K, Element)) end,
  lists:foreach(AssertPred, Data).

new_1_test() ->
  Table = create_table_aux(),
  ?assertEqual(new(?EL_ANON, Table), new(Table)).

append_raw_test() ->
  Table = create_table_aux(),
  Value = ?PARSER_NUMBER(9),
  Element = new(key, Table),
  % assert not fail
  append('NationalRank', Value, ?AQL_INTEGER, Element).

put_test() ->
  Table = create_table_aux(),
  El = new('1', Table),
  {ok, El1} = put([?PARSER_ATOM('NationalRank')], [?PARSER_NUMBER(3)], El),
  ?assertEqual(crdt:set_integer(3), get('NationalRank', ?CRDT_INTEGER, El1)).

get_default_test() ->
  Table = create_table_aux(),
  El = new(key, Table),
  ?assertEqual(crdt:set_integer(1), get('NationalRank', ?CRDT_INTEGER, El)).

foreign_keys_test() ->
  Fk = "PT",
  Keys = [?PARSER_ATOM('WorldRank'), ?PARSER_ATOM('InstitutionId')],
  Values = [?PARSER_NUMBER(1), ?PARSER_STRING(Fk)],
  Table = create_table_aux(),
  El = new(key, Table),
  {ok, El1} = put(Keys, Values, El),
  ?assertEqual([{'InstitutionId', {Fk, 'Institution'}}], foreign_keys(El1)).

-endif.
