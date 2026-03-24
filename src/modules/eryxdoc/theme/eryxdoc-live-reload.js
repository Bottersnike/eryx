// Lightweight live-reload client for eryxdoc dev server
(function () {
    const WS_PATH = "/__eryxdoc_ws";
    let socket = null;
    let retry = 1000;

    function connect() {
        try {
            socket = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + WS_PATH);
        } catch (e) {
            scheduleReconnect();
            return;
        }

        socket.addEventListener("open", function () {
            retry = 1000;
        });

        socket.addEventListener("message", function (ev) {
            if (!ev.data) return;
            if (ev.data === "reload") {
                try {
                    location.reload(true);
                } catch (e) {
                    location.reload();
                }
            }
        });

        socket.addEventListener("close", function () {
            scheduleReconnect();
        });

        socket.addEventListener("error", function () {
            socket.close();
        });
    }

    function scheduleReconnect() {
        setTimeout(function () {
            connect();
        }, retry);
        // backoff capped at 10s
        retry = Math.min(10000, Math.floor(retry * 1.5));
    }

    // Connect after DOM ready
    if (document.readyState === "complete" || document.readyState === "interactive") {
        connect();
    } else {
        document.addEventListener("DOMContentLoaded", connect);
    }
})();
