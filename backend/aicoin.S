#include "asm.inc"
#include "account.inc"
/*
 * aicoin.S - the backend's call to Claude, through the user's aicoin wallet.
 *
 * The proxy takes the same path the provider would (POST /v1/messages), picks
 * the upstream from X-AI, bills the wallet named by X-Api-Key and injects its
 * own provider key - so no Anthropic credential exists anywhere in asmedit,
 * and the per-account secret is the wallet token the user bound at
 * registration.
 *
 * Nothing above this file knows any of that: the editor asked its backend a
 * question and will get text back.
 */
#define REQ_IP          0
#define REQ_PORT        4
#define REQ_METHOD      8
#define REQ_PATH        16
#define REQ_HOST        24
#define REQ_HDRS        32
#define REQ_BODY        40
#define REQ_BODYLEN     48
#define REQ_OUT         56
#define REQ_OUTCAP      64

#define AI_BODY_SZ      32768
#define AI_RESP_SZ      65536
#define AI_HDR_SZ       1024

        CODE
        .p2align 2

/*
 * aicoin_ask - x0 = account, x1 = mode ("agent"/"aify"), x2 = context,
 *              x3 = baseline (may be empty), x4 = output, w5 = capacity
 *   out w0 = length of the reply text, or -1
 */
        .globl  SYM(aicoin_ask)
SYM(aicoin_ask):
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0                 /* account  */
        mov     x20, x1                 /* mode     */
        mov     x21, x2                 /* context  */
        mov     x22, x3                 /* baseline */
        mov     x23, x4                 /* out      */
        mov     w24, w5

/* ---- the request body --------------------------------------------------- */
        LEA     x25, ai_body
        mov     x0, x25
        LEA     x1, s_body_head
        bl      SYM(str_copy)
        mov     x25, x0

        mov     x0, x20                 /* which instruction fits this key? */
        LEA     x1, s_aify
        bl      SYM(str_eq)
        cbz     w0, 1f
        LEA     x1, s_prompt_aify
        b       2f
1:      LEA     x1, s_prompt_agent
2:      mov     x0, x25
        bl      SYM(str_copy)
        mov     x25, x0

        ldrb    w9, [x22]               /* a baseline only if there is one */
        cbz     w9, 3f
        mov     x0, x25
        LEA     x1, s_prev_head
        bl      SYM(str_copy)
        mov     x25, x0
        mov     x0, x25
        mov     x1, x22
        mov     w2, #(AI_BODY_SZ / 3)
        bl      SYM(json_escape)
        mov     x25, x0
3:      mov     x0, x25
        LEA     x1, s_cur_head
        bl      SYM(str_copy)
        mov     x25, x0
        mov     x0, x25
        mov     x1, x21
        mov     w2, #(AI_BODY_SZ / 3)
        bl      SYM(json_escape)
        mov     x25, x0
        mov     x0, x25
        LEA     x1, s_body_tail
        bl      SYM(str_copy)
        mov     x25, x0

/* ---- headers: which upstream, and whose wallet pays --------------------- */
        LEA     x0, ai_hdrs
        LEA     x1, s_hdr_head
        bl      SYM(str_copy)
        add     x1, x19, #ACCT_WALLET
        bl      SYM(str_copy)
        LEA     x1, s_crlf
        bl      SYM(str_copy)

/* ---- where is the proxy? ------------------------------------------------ */
        LEA     x0, s_env_aicoin
        bl      SYM(env_get)
        mov     x26, x0
        cbnz    x26, 4f
        LEA     x26, s_aicoin_default
4:      LEA     x27, ai_req
        mov     x0, x26
        add     x1, x27, #REQ_IP
        add     x2, x27, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbnz    w0, #31, .Lai_fail

        LEA     x0, s_post
        str     x0, [x27, #REQ_METHOD]
        LEA     x0, s_path_messages
        str     x0, [x27, #REQ_PATH]
        str     x26, [x27, #REQ_HOST]
        LEA     x0, ai_hdrs
        str     x0, [x27, #REQ_HDRS]
        LEA     x0, ai_body
        str     x0, [x27, #REQ_BODY]
        LEA     x0, ai_body
        bl      SYM(str_len)
        str     w0, [x27, #REQ_BODYLEN]
        LEA     x0, ai_resp
        str     x0, [x27, #REQ_OUT]
        mov     w0, #AI_RESP_SZ
        str     w0, [x27, #REQ_OUTCAP]
        mov     x0, x27
        bl      SYM(http_request)
        cmp     w0, #0
        b.le    .Lai_fail

/* ---- {"content":[{"type":"text","text":"..."}]} ------------------------- */
        LEA     x0, ai_resp
        bl      SYM(http_body)
        LEA     x1, s_key_text
        bl      SYM(json_find)
        cbnz    x0, 5f
        LEA     x0, ai_resp             /* no text: hand back the error body
                                           rather than pretend it worked */
        bl      SYM(http_body)
        mov     x1, x0
        mov     x0, x23
        mov     w2, w24
        bl      SYM(str_copy)
        LEA     x0, ai_resp
        bl      SYM(http_body)
        bl      SYM(str_len)
        b       .Lai_out
5:      mov     x1, x0
        mov     x0, x23
        mov     w2, w24
        bl      SYM(json_unescape)
        b       .Lai_out

.Lai_fail:
        mov     w0, #-1
.Lai_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

        CSTR
s_env_aicoin:      .asciz "ASMEDIT_AICOIN"
s_aicoin_default:  .asciz "127.0.0.1:8081"
s_post:            .asciz "POST"
s_path_messages:   .asciz "/v1/messages"
s_aify:            .asciz "aify"
s_crlf:            .asciz "\r\n"
s_key_text:        .asciz "\"text\""
s_hdr_head:        .asciz "Content-Type: application/json\r\nanthropic-version: 2023-06-01\r\nX-AI: anthropic\r\nX-Api-Key: "
s_body_head:       .asciz "{\"model\":\"claude-opus-5\",\"max_tokens\":16000,\"messages\":[{\"role\":\"user\",\"content\":\""
s_prompt_agent:    .asciz "You are inside asmedit, a text editor. The user pressed the ask key on this screen. Answer plainly. Use only ASCII letters, digits and simple punctuation - the editor renders a 5x7 bitmap font and cannot draw anything else.\\n\\n"
s_prompt_aify:     .asciz "You are inside asmedit, a text editor. Rewrite this screen, carrying out whatever the user's latest edit asks for. Reply with the new screen contents and nothing else - no preamble, no fences. Use only ASCII letters, digits and simple punctuation - the editor renders a 5x7 bitmap font and cannot draw anything else.\\n\\n"
s_prev_head:       .asciz "PREVIOUS VERSION OF THIS SCREEN:\\n"
s_cur_head:        .asciz "\\n\\nCURRENT SCREEN:\\n"
s_body_tail:       .asciz "\"}]}"

        BSS
        .p2align 4
ai_req:         .space 80
ai_body:        .space AI_BODY_SZ
ai_hdrs:        .space AI_HDR_SZ
ai_resp:        .space AI_RESP_SZ
