SELECT json('[1,]'), json_valid('[1,]'), json_valid('[1,]', 2), json_error_position('[1,]');
SELECT json('{a:1,}'), json_valid('{a:1,}');
SELECT json('{''a'':''b\''c"d''}');
SELECT json('[0x1F,0XFF, .5, 5., +1, -.5, Infinity, -Infinity, NaN, +Infinity]');
SELECT json('/* c */ [1, // x
 2]');
SELECT json('[''\x41\0\v'']');
SELECT json('{$x_1:2, é:3}');
SELECT json('''a\
b''');
SELECT json('[1e5, 1E+2, 0x7fffffffffffffffff]');
SELECT json('["é"]'), json_valid('["é"]');
SELECT json('{"a":1 , }');
SELECT json('[,]');
SELECT json('[1,,2]');
SELECT json('{a}');
SELECT json('[-0x10]');
SELECT json_extract('{a:1, b:[2, 3,]}', '$.b[1]'), '{a:{b:5}}' -> '$.a.b', '{a:{b:5}}' ->> 'a';
SELECT json_type('{a:1}', '$.a'), json_array_length('[1,2,]');
SELECT json_set('{a:1}', '$.b', 2);
SELECT key, value FROM json_each('{x:1, y:''z''}');
SELECT json_valid('[1]', 1), json_valid('[1,]', 1), json_valid('[1,]', 3);
