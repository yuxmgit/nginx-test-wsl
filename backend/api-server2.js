const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 4002;
const SERVER_NAME = '服务器B';

// 读取部署时由 Jenkins 写入的版本信息（位于 frontend/version.json）
function readVersionInfo() {
    const versionFile = path.resolve(__dirname, '..', 'frontend', 'version.json');
    try {
        return JSON.parse(fs.readFileSync(versionFile, 'utf8'));
    } catch (err) {
        return { version: 'unknown', shortCommit: 'unknown', error: err.message };
    }
}

const data = {
    '/api/user': {
        code: 200,
        message: 'success',
        server: SERVER_NAME,
        port: PORT,
        data: { id: 1, name: '张三', role: 'admin', loginAt: new Date().toISOString() }
    },
    '/api/products': {
        code: 200,
        message: 'success',
        server: SERVER_NAME,
        port: PORT,
        data: [
            { id: 101, name: 'iPhone 16', price: 7999 },
            { id: 102, name: 'MacBook Pro', price: 14999 },
            { id: 103, name: 'AirPods Pro', price: 1899 }
        ]
    },
    '/api/order': {
        code: 200,
        message: '订单创建成功',
        server: SERVER_NAME,
        port: PORT,
        data: { orderId: 'ORD-' + Date.now(), status: 'created', amount: 24897.00 }
    }
};

const server = http.createServer((req, res) => {
    res.writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*'
    });

    const route = req.url.split('?')[0];

    // 运行时版本查询：后端进程也报出当前部署的版本
    if (route === '/api/version') {
        const info = readVersionInfo();
        res.end(JSON.stringify({
            code: 200,
            message: 'success',
            server: SERVER_NAME,
            port: PORT,
            data: info
        }));
        return;
    }

    const body = data[route];

    if (body) {
        console.log(`[${new Date().toLocaleTimeString()}] ${SERVER_NAME} (4002) <- ${route}`);
        res.end(JSON.stringify(body));
    } else {
        res.end(JSON.stringify({ code: 404, message: 'Not Found', server: SERVER_NAME }));
    }
});

server.listen(PORT, () => {
    console.log(`[${SERVER_NAME}] API 服务器已启动，监听端口 ${PORT}`);
});
