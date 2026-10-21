const http = require('http');

const PORT = 4001;
const SERVER_NAME = '服务器A';

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
    const body = data[route];

    if (body) {
        console.log(`[${new Date().toLocaleTimeString()}] ${SERVER_NAME} (4001) <- ${route}`);
        res.end(JSON.stringify(body));
    } else {
        res.end(JSON.stringify({ code: 404, message: 'Not Found', server: SERVER_NAME }));
    }
});

server.listen(PORT, () => {
    console.log(`[${SERVER_NAME}] API 服务器已启动，监听端口 ${PORT}`);
});
