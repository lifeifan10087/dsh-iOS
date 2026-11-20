// 把 Node 的平台谎报成 darwin/arm64，用来提前暴露 iOS 上的加载错误
Object.defineProperty(process, 'platform', { value: 'darwin' });
Object.defineProperty(process, 'arch', { value: 'arm64' });
