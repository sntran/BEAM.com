// The service worker of the page (sw.js) adds this script to each HTML page
// of the VM. It does three things:
// - A service worker cannot take a WebSocket. So a socket to this site goes
//   to the VM through the tab of index.html (a message port), and the VM
//   runs its upgrade. The message goes to the top window, the tab of
//   index.html. Another socket is a real one.
// - A service worker cannot open the SharedWorker of the VM. So it gives a
//   request of this frame to this frame, and this frame gives it to its
//   tab, which gives it to the VM.
// - A link or a form of the app with a path outside the frame (for
//   example href="/", which an app writes without its base path) goes to
//   the same path in the frame. Without this, the browser leaves the scope
//   of the service worker, and the site gives a 404.
(() => {
  const APP = new URL('./app/', document.currentScript?.src ?? location.href);
  const outside = (u) => u.origin === location.origin && !`${u.pathname}/`.startsWith(APP.pathname);
  const inApp = (u) => new URL(APP.pathname.replace(/\/$/, '') + u.pathname + u.search + u.hash, u).href;

  addEventListener('click', (e) => {
    const a = e.target instanceof Element ? e.target.closest('a[href]') : null;
    if (!a || a.hasAttribute('download') || (a.target && a.target !== '_self')) return;
    const u = new URL(a.href);
    if (outside(u)) a.href = inApp(u);
  }, true);
  addEventListener('submit', (e) => {
    const form = e.target;
    if (!(form instanceof HTMLFormElement)) return;
    const u = new URL(form.action);
    if (outside(u)) form.action = inApp(u);
  }, true);

  const Native = window.WebSocket;
  const top = window.top;
  if (!top || top === window) return;

  const sw = navigator.serviceWorker;
  if (sw) {
    sw.addEventListener('message', (e) => {
      if (e.data?.type === 'fetch') top.postMessage(e.data, location.origin, [...e.ports]);
    });
    sw.startMessages();
    sw.controller?.postMessage({ type: 'frame' });
  }

  class VmSocket extends EventTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url, protocols) {
      super();
      this.url = url.href;
      this.readyState = 0;
      this.protocol = '';
      this.extensions = '';
      this.bufferedAmount = 0;
      this.binaryType = 'blob';
      this.onopen = this.onmessage = this.onclose = this.onerror = null;
      const { port1, port2 } = new MessageChannel();
      this.port = port1;
      port1.onmessage = (e) => this.receive(e.data);
      const list = protocols === undefined ? [] : [].concat(protocols);
      top.postMessage({ type: 'ws', path: url.pathname + url.search, protocols: list }, location.origin, [port2]);
    }

    receive(m) {
      if (m.open) {
        this.readyState = 1;
        this.protocol = m.protocol ?? '';
        this.emit(new Event('open'));
      } else if (m.message !== undefined) {
        let data = m.message;
        if (data instanceof ArrayBuffer && this.binaryType === 'blob') data = new Blob([data]);
        this.emit(new MessageEvent('message', { data, origin: location.origin }));
      } else if (m.close) {
        if (this.readyState === 3) return;
        const wasOpen = this.readyState === 1;
        this.readyState = 3;
        this.port.close();
        if (!wasOpen || m.error) this.emit(new Event('error'));
        this.emit(new CloseEvent('close', { code: m.code ?? 1006, reason: m.reason ?? '', wasClean: !m.error }));
      }
    }

    send(data) {
      if (this.readyState === 0) throw new DOMException('Still in CONNECTING state.', 'InvalidStateError');
      if (this.readyState !== 1) return;
      if (data instanceof Blob) {
        data.arrayBuffer().then((b) => this.port.postMessage({ message: b }, [b]));
      } else if (ArrayBuffer.isView(data)) {
        this.port.postMessage({ message: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) });
      } else {
        this.port.postMessage({ message: data });
      }
    }

    close(code = 1000, reason = '') {
      if (this.readyState >= 2) return;
      this.readyState = 2;
      this.port.postMessage({ close: true, code, reason });
    }

    emit(event) {
      this.dispatchEvent(event);
      this[`on${event.type}`]?.(event);
    }
  }

  window.WebSocket = function WebSocket(url, protocols) {
    const u = new URL(url, location.href);
    if (u.host === location.host) return new VmSocket(u, protocols);
    return protocols === undefined ? new Native(url) : new Native(url, protocols);
  };
  Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3, prototype: Native.prototype });
})();
