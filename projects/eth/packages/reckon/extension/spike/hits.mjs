import http from 'node:http'; const hits = [];
http.createServer((q, s) => { hits.push(q.url); console.log('HIT', q.url); s.end('x'); }).listen(8899, '127.0.0.1');
