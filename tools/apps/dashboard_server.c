// dashboard_server.c — Minimal HTTP server that calls Rail for HTML generation
// Compile: cc -O2 -o tools/dashboard tools/dashboard_server.c
// Run: ./tools/dashboard
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>

#define PORT 9091
#define BUF 8192
#define DIR "training/self_train"
#define REGEN "./rail_native run tools/train/train_dashboard.rail 2>/dev/null"

static char html[1<<17]; // 128KB buffer
static int html_len = 0;

void regen(void) {
    system(REGEN);  // Rail regenerates dashboard.html
    FILE *f = fopen(DIR "/dashboard.html", "r");
    if (!f) return;
    html_len = fread(html, 1, sizeof(html)-1, f);
    html[html_len] = 0;
    fclose(f);
}

void url_decode(const char *src, char *dst, int max) {
    int i=0, j=0;
    while (src[i] && j < max-1) {
        if (src[i]=='%' && src[i+1] && src[i+2]) {
            int v; sscanf(src+i+1, "%2x", &v);
            dst[j++] = v; i += 3;
        } else if (src[i]=='+') { dst[j++]=' '; i++; }
        else dst[j++] = src[i++];
    }
    dst[j] = 0;
}

void handle(int cl) {
    char req[BUF];
    int n = read(cl, req, BUF-1);
    if (n <= 0) { close(cl); return; }
    req[n] = 0;

    char method[8]={}, path[4096]={};
    sscanf(req, "%7s %4095s", method, path);

    // Handle actions from query string
    if (strstr(path, "?start")) {
        if (system("pgrep -f self_train >/dev/null 2>&1") != 0)
            system("cd " DIR "/../../ && nohup ./rail_native run tools/train/self_train.rail > " DIR "/stdout.log 2>&1 &");
        fprintf(stderr, "  ▶ Start\n");
    } else if (strstr(path, "?stop")) {
        system("pkill -f self_train 2>/dev/null; pkill -f rail_st 2>/dev/null");
        fprintf(stderr, "  ■ Stop\n");
    } else if (strstr(path, "?savegoals=")) {
        char *g = strstr(path, "?savegoals=") + 11;
        char decoded[4096];
        url_decode(g, decoded, sizeof(decoded));
        FILE *f = fopen(DIR "/goals.txt", "w");
        if (f) { fputs(decoded, f); fclose(f); }
        fprintf(stderr, "  ✓ Goals saved\n");
    } else if (strstr(path, "?config&")) {
        // Parse config params from URL
        char *q = strstr(path, "?config&") + 8;
        char decoded[4096];
        url_decode(q, decoded, sizeof(decoded));
        // Replace & with newlines
        for (char *p = decoded; *p; p++) if (*p == '&') *p = '\n';
        FILE *f = fopen(DIR "/config.txt", "w");
        if (f) { fputs(decoded, f); fclose(f); }
        fprintf(stderr, "  ⚙ Config saved\n");
    }

    // For action requests, serve a tiny "OK" to the fetch()
    if (strstr(path, "?start") || strstr(path, "?stop") ||
        strstr(path, "?savegoals") || strstr(path, "?config")) {
        char *ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nOK";
        write(cl, ok, strlen(ok));
        close(cl);
        return;
    }

    // GET / — serve dashboard (regenerate first)
    regen();
    char hdr[256];
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        "Content-Length: %d\r\nConnection: close\r\n\r\n", html_len);
    write(cl, hdr, hlen);
    write(cl, html, html_len);
    close(cl);
}

int main(void) {
    signal(SIGCHLD, SIG_IGN);  // Reap children
    signal(SIGPIPE, SIG_IGN);  // Ignore broken pipes

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = { .sin_family=AF_INET, .sin_port=htons(PORT), .sin_addr.s_addr=INADDR_ANY };
    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(srv, 16);

    chdir(getenv("HOME"));
    chdir("projects/rail");

    printf("Rail Self-Training Dashboard\n");
    printf("  http://localhost:%d\n", PORT);
    printf("  Ctrl+C to stop\n\n");
    fflush(stdout);

    // Pre-generate
    regen();
    system("open http://localhost:" "9091" " 2>/dev/null &");

    for (;;) {
        int cl = accept(srv, NULL, NULL);
        if (cl < 0) continue;
        if (fork() == 0) { close(srv); handle(cl); _exit(0); }
        close(cl);
    }
}
