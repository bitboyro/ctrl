"""A tiny local HTTP application; Python standard library only."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import TCPServer


def greeting(name):
    return 'Hello, ' + name + '!'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/health'):
            self.send_error(404)
            return
        body = ('ok' if self.path == '/health' else greeting('world')).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class LocalHTTPServer(HTTPServer):
    def server_bind(self):
        # This example binds a numeric loopback address. HTTPServer's reverse DNS
        # lookup can stall startup on hosts with an unavailable resolver.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8080)
    port = parser.parse_args().port
    if not 1024 <= port <= 65535:
        parser.error('port must be between 1024 and 65535')
    server = LocalHTTPServer(('127.0.0.1', port), Handler)
    print('Listening on http://127.0.0.1:' + str(port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
