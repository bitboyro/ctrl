'use strict';
const http = require('http');
function greeting(name) { return `Hello, ${name}!`; }
function main() {
  const port = Number(process.argv[2] || 3000);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error('port must be between 1024 and 65535');
  }
  const server = http.createServer((req, res) => {
    if (req.url !== '/' && req.url !== '/health') {
      res.writeHead(404); res.end('not found'); return;
    }
    res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
    res.end(req.url === '/health' ? 'ok' : greeting('world'));
  });
  server.listen(port, '127.0.0.1', () => console.log(`Listening on http://127.0.0.1:${port}`));
}
module.exports = {greeting};
if (require.main === module) main();
