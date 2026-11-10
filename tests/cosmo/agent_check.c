/*
 * The check of the connection of c_src/cosmo/beam_com_agent.c to the pipe
 * of an agent on Windows: the server of the pipe gets a token of the level
 * SecurityIdentification, not SecurityImpersonation. So a server that a
 * local user makes with the name of the pipe cannot act as the client.
 * On the other systems, the check does nothing. The last line is
 * "agent_check: ok".
 */
#include "../../c_src/cosmo/beam_com_agent.c"

#include <pthread.h>
#include "libc/nt/dll.h"
#include "libc/nt/enum/filesharemode.h"
#include "libc/nt/ipc.h"
#include "libc/nt/thread.h"

#define PIPE_NAME "//./pipe/beam_com_agent_check"
#define TOKEN_QUERY 0x0008u
#define TOKEN_IMPERSONATION_LEVEL 9 /* TokenImpersonationLevel */

typedef bool32 __attribute__((__ms_abi__)) (*impersonate_f)(int64_t);
typedef bool32 __attribute__((__ms_abi__)) (*revert_f)(void);
typedef bool32 __attribute__((__ms_abi__)) (*open_token_f)(int64_t, uint32_t,
                                                           bool32, int64_t *);
typedef bool32 __attribute__((__ms_abi__)) (*token_info_f)(int64_t, int, void *,
                                                           uint32_t, uint32_t *);

static int64_t server = -1;

static void *client(void *arg)
{
    struct agent a;
    (void)arg;
    if (agent_open(PIPE_NAME, &a) == 0) {
        unsigned char b = 1;
        agent_write(&a, &b, 1);
        agent_read(&a, &b, 1); /* until the server closes */
        CloseHandle(a.handle);
    }
    return 0;
}

int main(void)
{
    char16_t name[] = u"\\\\.\\pipe\\beam_com_agent_check";
    int64_t advapi, token = 0;
    uint32_t level = 0, len = 0, got = 0;
    unsigned char b;
    impersonate_f impersonate;
    revert_f revert;
    open_token_f open_token;
    token_info_f token_info;
    pthread_t t;

    if (!IsWindows()) {
        printf("agent_check: ok (not Windows)\n");
        return 0;
    }
    advapi = LoadLibrary(u"advapi32.dll");
    impersonate = (impersonate_f)GetProcAddress(advapi, "ImpersonateNamedPipeClient");
    revert = (revert_f)GetProcAddress(advapi, "RevertToSelf");
    open_token = (open_token_f)GetProcAddress(advapi, "OpenThreadToken");
    token_info = (token_info_f)GetProcAddress(advapi, "GetTokenInformation");
    if (!impersonate || !revert || !open_token || !token_info) {
        printf("agent_check: no function of advapi32\n");
        return 1;
    }
    server = CreateNamedPipe(name, kNtPipeAccessDuplex,
                             kNtPipeTypeByte | kNtPipeReadmodeByte, 1, 4096,
                             4096, 0, 0);
    if (server == -1) {
        printf("agent_check: no pipe\n");
        return 1;
    }
    pthread_create(&t, 0, client, 0);
    if (!ConnectNamedPipe(server, 0) && GetLastError() != kNtErrorPipeConnected) {
        printf("agent_check: no client\n");
        return 1;
    }
    /* One byte first: a server can impersonate only after a read. */
    ReadFile(server, &b, 1, &got, 0);
    if (!impersonate(server)) {
        printf("agent_check: no impersonation (%u)\n", GetLastError());
        return 1;
    }
    if (!open_token(GetCurrentThread(), TOKEN_QUERY, 1, &token) ||
        !token_info(token, TOKEN_IMPERSONATION_LEVEL, &level, sizeof(level), &len)) {
        revert();
        printf("agent_check: no token (%u)\n", GetLastError());
        return 1;
    }
    revert();
    CloseHandle(token);
    CloseHandle(server);
    pthread_join(t, 0);
    printf("agent_check: the level of the token is %u (1: SecurityIdentification)\n",
           level);
    if (level != 1) {
        printf("agent_check: the server can act as the client\n");
        return 1;
    }
    printf("agent_check: ok\n");
    return 0;
}
