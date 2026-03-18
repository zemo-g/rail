// llm.c - Native LLM call for Rail
// Linked into Rail binaries that use the `llm` builtin.
// llm port sys_prompt user_prompt -> response string
//
// Builds a curl command, calls popen, extracts content via jq.
// Much faster than Rail-level string escaping + shell.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// JSON-escape a string in-place into a buffer
static int json_escape(const char *src, char *dst, int max) {
    int j = 0;
    for (int i = 0; src[i] && j < max - 2; i++) {
        char c = src[i];
        if (c == '"') { dst[j++] = '\\'; dst[j++] = '"'; }
        else if (c == '\\') { dst[j++] = '\\'; dst[j++] = '\\'; }
        else if (c == '\n') { dst[j++] = '\\'; dst[j++] = 'n'; }
        else if (c == '\r') { dst[j++] = '\\'; dst[j++] = 'r'; }
        else if (c == '\t') { dst[j++] = '\\'; dst[j++] = 't'; }
        else dst[j++] = c;
    }
    dst[j] = 0;
    return j;
}

// _rail_llm(port_str, sys_prompt, user_prompt) -> char*
// port_str is a Rail string (raw pointer to C string since Rail strings are C strings)
char *rail_llm(const char *port_str, const char *sys_prompt, const char *user_prompt) {
    // Escape prompts
    int sys_len = strlen(sys_prompt);
    int usr_len = strlen(user_prompt);
    char *esc_sys = malloc(sys_len * 2 + 1);
    char *esc_usr = malloc(usr_len * 2 + 1);
    json_escape(sys_prompt, esc_sys, sys_len * 2);
    json_escape(user_prompt, esc_usr, usr_len * 2);

    // Build the request JSON file
    char *req = malloc(sys_len * 2 + usr_len * 2 + 512);
    snprintf(req, sys_len * 2 + usr_len * 2 + 512,
        "{\"messages\": ["
        "{\"role\": \"system\", \"content\": \"%s\"}, "
        "{\"role\": \"user\", \"content\": \"%s\"}], "
        "\"max_tokens\": 4096, \"temperature\": 0.3, "
        "\"chat_template_kwargs\": {\"enable_thinking\": false}}",
        esc_sys, esc_usr);

    FILE *f = fopen("/tmp/rail_llm_req.json", "w");
    if (f) { fputs(req, f); fclose(f); }

    // Build curl command
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "curl -s http://localhost:%s/v1/chat/completions "
        "-H 'Content-Type: application/json' "
        "-d @/tmp/rail_llm_req.json 2>/dev/null | "
        "jq -r '.choices[0].message.content // empty' 2>/dev/null",
        port_str);

    // Execute via popen
    FILE *p = popen(cmd, "r");
    char *result = malloc(65536);
    size_t total = 0;
    if (p) {
        size_t n;
        while ((n = fread(result + total, 1, 4096, p)) > 0)
            total += n;
        pclose(p);
    }
    result[total] = 0;

    // Strip trailing newline
    if (total > 0 && result[total-1] == '\n')
        result[total-1] = 0;

    // Strip markdown code fences if present
    if (strncmp(result, "```", 3) == 0) {
        char *start = strchr(result, '\n');
        if (start) {
            start++;
            char *end = strstr(start, "\n```");
            if (end) *end = 0;
            char *clean = malloc(strlen(start) + 1);
            strcpy(clean, start);
            free(result);
            result = clean;
        }
    }

    free(req);
    free(esc_sys);
    free(esc_usr);
    return result;
}
