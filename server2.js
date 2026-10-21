const http = require('http');

const PORT = 3002;
const serverName = '服务器B (端口 3002)';

let requestCount = 0;

const server = http.createServer((req, res) => {
  requestCount++;
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`
    <!DOCTYPE html>
    <html>
    <head>
      <title>${serverName}</title>
      <style>
        body {
          font-family: 'Microsoft YaHei', sans-serif;
          display: flex;
          justify-content: center;
          align-items: center;
          height: 100vh;
          margin: 0;
          background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
          color: white;
        }
        .card {
          background: rgba(255,255,255,0.15);
          backdrop-filter: blur(10px);
          padding: 40px 60px;
          border-radius: 16px;
          text-align: center;
          box-shadow: 0 8px 32px rgba(0,0,0,0.2);
        }
        h1 { margin: 0 0 20px 0; font-size: 2em; }
        .count { font-size: 1.2em; margin-top: 20px; }
        .badge {
          display: inline-block;
          background: #4ecdc4;
          padding: 6px 16px;
          border-radius: 20px;
          font-weight: bold;
          margin-bottom: 10px;
        }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="badge">Server B</div>
        <h1>${serverName}</h1>
        <p>这是第二个后端服务器</p>
        <div class="count">已处理请求数: <strong>${requestCount}</strong></div>
      </div>
    </body>
    </html>
  `);
});

server.listen(PORT, () => {
  console.log(`${serverName} 已启动，监听端口 ${PORT}`);
});
