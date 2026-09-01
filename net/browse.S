#include "asm.inc"
/*
 * browse.S - fetching a page, by whichever route works.
 *
 * A site is a thing the editor can open, not a thing a browser opens. You
 * write "open google", press Cmd+Enter, and the next screen is what was
 * there - the same key that asks a model a question, because opening a page
 * and asking for an answer are the same request with different sources.
 *
 * <h2>Two routes, and why both</h2>
 *
 * Directly: resolve the name, open a socket, send a GET, turn the reply into
 * text. That is the whole of it, and it is better whenever it works - nothing
 * in the middle, nothing logged elsewhere, and no dependency on a backend
 * being up.
 *
 * Through the backend: ask it to fetch and hand back the text. That works
 * where direct does not - behind a captive portal, on a machine with no name
 * server, over HTTPS that this editor cannot yet speak - and it costs a round
 * trip through somebody else's machine, which is a real cost and not only a
 * latency one: the backend learns which pages were opened.
 *
 * So: direct first, backend when direct fails, and remember which one worked
 * per host so the second visit does not repeat the discovery. That memory is
 * the whole of the "balancing". It is deliberately not a race between the two
 * routes - racing would fetch every page twice, and the loser's request is
 * still a request that arrived at somebody's server.
 *
 * <h2>What this is not</h2>
 *
 * There is no HTTPS here yet, and that is most of the web. A site that
 * redirects to https is a site that this reaches through the backend, and it
 * will keep being one until the TLS handshake in crypto/ is finished. Saying
 * so plainly beats a browser that silently sends everything through a proxy
 * while looking like it went direct.
 */

#define PAGE_SZ         65536
#define HDR_SZ          512
#define MAX_REDIRECT    3
#define REMEMBER        16      /* hosts whose working route we know */

#define ROUTE_UNKNOWN   0
#define ROUTE_DIRECT    1
#define ROUTE_BACKEND   2

        CODE
        .p2align 2

/*
 * browse_open - x0 = what the person wrote, x1 = out, w2 = capacity.
 *   out w0 = bytes of text, or -1 if neither route produced a page.
 *
 * "what the person wrote" is not a URL. It is "google", "news.ycombinator.com",
 * "http://example.com/path" or anything else somebody types when they mean a
 * site, and turning that into a request is this function's first job - see
 * browse_url.
 */
        .globl  SYM(browse_open)
SYM(browse_open):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]
        mov     x19, x0                 /* what they wrote */
        mov     x20, x1                 /* out             */
        mov     w21, w2                 /* capacity        */

        mov     x0, x19
        LEA     x1, br_host
        LEA     x2, br_path
        bl      browse_url
        cmn     w0, #1
        b.eq    .Lbo_fail
        mov     w22, w0                 /* the port they asked for */

/*
 * https goes to the backend without trying, because trying would not fail -
 * it would connect to port 443 and send a plain-text GET, and a TLS server
 * answers that with "400 The plain HTTP request was sent to HTTPS port",
 * which is a page. It parses. It renders. It lands on the screen looking like
 * the site said it, and the fallback never runs because nothing failed.
 *
 * A route that cannot work should not be attempted, exactly so that failure
 * stays recognisable.
 */
        LEA     x9, br_secure
        ldr     w9, [x9]
        cbnz    w9, .Lbo_backend

        /* Whichever route worked last time for this host goes first. */
        LEA     x0, br_host
        bl      browse_recall
        cmp     w0, #ROUTE_BACKEND
        b.eq    .Lbo_backend

.Lbo_direct:
        mov     w0, w22
        mov     x1, x20
        mov     w2, w21
        bl      browse_direct
        cmn     w0, #1
        b.eq    .Lbo_backend
        mov     w23, w0
        LEA     x0, br_host
        mov     w1, #ROUTE_DIRECT
        bl      browse_remember
        mov     w0, w23
        b       .Lbo_out

.Lbo_backend:
        mov     x0, x19
        mov     x1, x20
        mov     w2, w21
        bl      SYM(browse_via_backend)
        cmn     w0, #1
        b.eq    .Lbo_fail
        mov     w23, w0
        LEA     x0, br_host
        mov     w1, #ROUTE_BACKEND
        bl      browse_remember
        mov     w0, w23
        b       .Lbo_out

.Lbo_fail:
        mov     w0, #-1
.Lbo_out:
        ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * browse_direct - w0 = port, x1 = out, w2 = capacity.
 *   out w0 = bytes of text, or -1.
 *
 * The host and path have already been parsed into br_host and br_path.
 */
browse_direct:
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

        LEA     x0, br_host
        bl      SYM(dns_resolve)
        cmn     w0, #1
        b.eq    .Lbd_fail               /* no name server, or no such name */
        mov     w22, w0

        mov     w0, w22
        mov     w1, w19
        bl      SYM(sock_open)
        cmn     w0, #1
        b.eq    .Lbd_fail
        mov     w23, w0

/*
 * GET /path HTTP/1.0, with a Host header.
 *
 * 1.0 on purpose. 1.1 lets a server answer with Transfer-Encoding: chunked,
 * and then the body is not the body - it is chunk lengths in hex interleaved
 * with the content, which arrived on screen as a stray "22f" above the page
 * and a "0" below it. Decoding that is thirty lines that exist only to undo
 * something we can decline to ask for.
 *
 * The Host header is sent anyway, which 1.0 does not require and every virtual
 * host needs. Servers accept the combination universally; it is what every
 * minimal client has sent for twenty years.
 */
        /* GET /path HTTP/1.0, Host, and a close so the read has an end. */
        LEA     x0, br_req
        LEA     x1, s_get
        bl      SYM(str_copy)
        LEA     x1, br_path
        bl      SYM(str_copy)
        LEA     x1, s_http11
        bl      SYM(str_copy)
        LEA     x1, br_host
        bl      SYM(str_copy)
        LEA     x1, s_hdrtail
        bl      SYM(str_copy)

        LEA     x0, br_req
        bl      SYM(str_len)
        mov     w2, w0
        mov     w0, w23
        LEA     x1, br_req
        bl      SYM(sock_write)
        tbnz    w0, #31, .Lbd_close

        /* Read until the far side closes; it said it would. */
        mov     w24, #0
1:      mov     w0, w23
        LEA     x1, br_page
        add     x1, x1, w24, uxtw
        mov     w2, #PAGE_SZ
        sub     w2, w2, w24
        sub     w2, w2, #1
        cmp     w2, #0
        b.le    2f
        bl      SYM(sock_read)
        cmp     w0, #0
        b.le    2f
        add     w24, w24, w0
        b       1b
2:      LEA     x9, br_page
        strb    wzr, [x9, w24, uxtw]

        mov     w0, w23
        bl      SYM(sock_close)
        cbz     w24, .Lbd_fail

/*
 * Only a 200 counts as having fetched the page.
 *
 * Anything else is a page about not fetching the page: a 301 to the https
 * version of the same site has an empty body, renders to nothing, and would
 * be reported as a successful fetch of a blank document. Handing those to the
 * backend instead is not a workaround - the backend follows redirects and
 * speaks TLS, so it is the route that can actually answer them.
 */
        LEA     x0, br_page
        LEA     x1, s_200
        bl      SYM(str_starts)
        cbz     w0, .Lbd_fail

        /* Past the headers, then whatever HTML is left becomes text. */
        LEA     x0, br_page
        mov     w1, w24
        bl      browse_body
        cbz     x0, .Lbd_fail
        mov     x1, x0                  /* body */
        LEA     x9, br_page
        add     x9, x9, w24, uxtw
        sub     w2, w9, w1              /* how much of it there is */

        mov     x0, x1
        mov     w1, w2
        mov     x2, x20
        mov     w3, w21
        mov     x4, #0
        mov     w5, #0
        bl      SYM(html_render)
        b       .Lbd_out

.Lbd_close:
        mov     w0, w23
        bl      SYM(sock_close)
.Lbd_fail:
        mov     w0, #-1
.Lbd_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * browse_body - x0 = the whole response, w1 = its length.
 *   out x0 = where the body starts, or 0.
 *
 * The blank line, found rather than assumed: a server may send any number of
 * headers and this editor has opinions about none of them.
 */
browse_body:
        mov     x2, x0
        mov     w3, w1
        mov     w4, #0
1:      add     w5, w4, #3
        cmp     w5, w3
        b.hs    8f
        ldrb    w6, [x2, w4, uxtw]
        cmp     w6, #'\r'
        b.ne    2f
        add     w5, w4, #1
        ldrb    w6, [x2, w5, uxtw]
        cmp     w6, #'\n'
        b.ne    2f
        add     w5, w4, #2
        ldrb    w6, [x2, w5, uxtw]
        cmp     w6, #'\r'
        b.ne    2f
        add     w5, w4, #3
        ldrb    w6, [x2, w5, uxtw]
        cmp     w6, #'\n'
        b.ne    2f
        add     w4, w4, #4
        add     x0, x2, w4, uxtw
        ret
2:      /* A bare LF LF, because not every server is careful. */
        ldrb    w6, [x2, w4, uxtw]
        cmp     w6, #'\n'
        b.ne    3f
        add     w5, w4, #1
        ldrb    w6, [x2, w5, uxtw]
        cmp     w6, #'\n'
        b.ne    3f
        add     w4, w4, #2
        add     x0, x2, w4, uxtw
        ret
3:      add     w4, w4, #1
        b       1b
8:      mov     x0, #0
        ret

/*
 * browse_url - x0 = what they wrote, x1 = host out, x2 = path out.
 *   out w0 = the port, or -1 if this cannot be a site at all.
 *
 * "google" is a site. So is "google.com", "http://google.com" and
 * "http://google.com/search?q=x". A bare word with no dot gets ".com", which
 * is a guess and the same guess every address bar has made for thirty years.
 *
 * https is parsed and then handed to the backend, because this editor cannot
 * speak it yet. Returning the port and letting the caller find out would be
 * worse: it would connect to 443 in clear text and read nothing.
 */
browse_url:
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     w22, #80
        LEA     x9, br_secure           /* until the scheme says otherwise */
        str     wzr, [x9]

        /* A scheme, if there is one. */
        mov     x0, x19
        LEA     x1, s_https
        bl      browse_prefix
        cbz     w0, 1f
        add     x19, x19, #8
        mov     w22, #443
        LEA     x9, br_secure
        mov     w10, #1
        str     w10, [x9]
        b       2f
1:      mov     x0, x19
        LEA     x1, s_http
        bl      browse_prefix
        cbz     w0, 2f
        add     x19, x19, #7
2:

        /* The host: up to a slash, a colon or the end. */
        mov     w23, #0                 /* did we see a dot? */
        mov     w24, #0
3:      ldrb    w9, [x19]
        cbz     w9, 4f
        cmp     w9, #'/'
        b.eq    4f
        cmp     w9, #':'
        b.eq    4f
        cmp     w9, #' '
        b.ls    4f
        cmp     w9, #'.'
        b.ne    5f
        mov     w23, #1
5:      cmp     w24, #250
        b.hs    4f
        cmp     w9, #'A'
        b.lo    6f
        cmp     w9, #'Z'
        b.hi    6f
        add     w9, w9, #32             /* host names are not case sensitive,
                                           and lower case is what the memory of
                                           routes is keyed on */
6:      strb    w9, [x20, w24, uxtw]
        add     w24, w24, #1
        add     x19, x19, #1
        b       3b
4:      cbz     w24, .Lbu_fail
        cbnz    w23, 7f
        /* No dot: "google" means google.com, the way it always has. */
        LEA     x9, s_dotcom
        mov     w10, #0
8:      ldrb    w11, [x9, w10, uxtw]
        cbz     w11, 7f
        cmp     w24, #250
        b.hs    7f
        strb    w11, [x20, w24, uxtw]
        add     w24, w24, #1
        add     w10, w10, #1
        b       8b
7:      strb    wzr, [x20, w24, uxtw]

        /* An explicit port replaces the scheme's. */
        ldrb    w9, [x19]
        cmp     w9, #':'
        b.ne    9f
        add     x19, x19, #1
        mov     w22, #0
10:     ldrb    w9, [x19]
        sub     w9, w9, #'0'
        cmp     w9, #9
        b.hi    9f
        mov     w10, #10
        madd    w22, w22, w10, w9
        add     x19, x19, #1
        b       10b
9:

        /* Whatever is left is the path, and "/" if nothing is. */
        ldrb    w9, [x19]
        cmp     w9, #'/'
        b.eq    11f
        mov     w9, #'/'
        strb    w9, [x21]
        strb    wzr, [x21, #1]
        b       12f
11:     mov     w10, #0
13:     ldrb    w9, [x19, w10, uxtw]
        cbz     w9, 14f
        cmp     w9, #' '
        b.ls    14f
        cmp     w10, #250
        b.hs    14f
        strb    w9, [x21, w10, uxtw]
        add     w10, w10, #1
        b       13b
14:     strb    wzr, [x21, w10, uxtw]
12:
        mov     w0, w22
        b       .Lbu_out
.Lbu_fail:
        mov     w0, #-1
.Lbu_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/* browse_prefix - x0 = text, x1 = a lower-case prefix, out w0 = 1 if it fits. */
browse_prefix:
1:      ldrb    w9, [x1]
        cbz     w9, 8f
        ldrb    w10, [x0]
        cbz     w10, 9f
        cmp     w10, #'A'
        b.lo    2f
        cmp     w10, #'Z'
        b.hi    2f
        add     w10, w10, #32
2:      cmp     w9, w10
        b.ne    9f
        add     x0, x0, #1
        add     x1, x1, #1
        b       1b
8:      mov     w0, #1
        ret
9:      mov     w0, #0
        ret

/*
 * browse_recall / browse_remember - which route worked for this host.
 *
 * Sixteen hosts, oldest overwritten. This is not a cache of pages and must not
 * become one: it holds a route, so being wrong costs one failed attempt and a
 * retry down the other path, never a stale page.
 */
browse_recall:
        stp     x29, x30, [sp, #-48]!   /* it calls something, so it needs a
                                           frame: without one, browse_same's
                                           return overwrote x30 and this
                                           returned into its own middle - and
                                           from there into a string, which the
                                           CPU tried to execute */
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0                 /* the host, kept: x0 becomes a result */
        mov     w20, #0

1:      cmp     w20, #REMEMBER
        b.hs    9f
        LEA     x9, br_routes
        mov     w10, #264
        madd    x21, x20, x10, x9
        ldrb    w9, [x21]
        cbz     w9, 9f                  /* an empty slot ends the list */
        mov     x1, x21
        mov     x2, x19
        bl      browse_same
        cbnz    w0, 8f
        add     w20, w20, #1
        b       1b

8:      ldrb    w0, [x21, #256]
        b       .Lbr_out
9:      mov     w0, #ROUTE_UNKNOWN
.Lbr_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* browse_same - x1, x2 = two NUL-terminated names, out w0 = 1 if equal. */
browse_same:
        mov     x3, x1
        mov     x4, x2
1:      ldrb    w9, [x3]
        ldrb    w10, [x4]
        cmp     w9, w10
        b.ne    9f
        cbz     w9, 8f
        add     x3, x3, #1
        add     x4, x4, #1
        b       1b
8:      mov     w0, #1
        ret
9:      mov     w0, #0
        ret

/* browse_remember - x0 = host, w1 = the route that worked. */
browse_remember:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     w20, w1

        LEA     x9, br_next
        ldr     w21, [x9]
        LEA     x9, br_routes
        mov     w10, #264
        madd    x21, x21, x10, x9

        mov     w10, #0
1:      cmp     w10, #255
        b.hs    2f
        ldrb    w11, [x19, w10, uxtw]
        strb    w11, [x21, w10, uxtw]
        cbz     w11, 2f
        add     w10, w10, #1
        b       1b
2:      strb    wzr, [x21, #255]
        strb    w20, [x21, #256]

        LEA     x9, br_next
        ldr     w10, [x9]
        add     w10, w10, #1
        cmp     w10, #REMEMBER
        csel    w10, wzr, w10, eq
        str     w10, [x9]

        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        RODATA
s_get:      .asciz "GET "
s_http11:   .asciz " HTTP/1.0\r\nHost: "
s_hdrtail:  .asciz "\r\nUser-Agent: armedit/0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n"
s_http:     .asciz "http://"
s_https:    .asciz "https://"
s_dotcom:   .asciz ".com"
s_200:      .asciz "HTTP/1.1 200"

        BSS
        .p2align 3
br_host:    .space 256
br_path:    .space 256
br_req:     .space 1024
br_routes:  .space (264 * REMEMBER)
br_next:    .space 4
br_secure:  .space 4
        .p2align 3
br_page:    .space PAGE_SZ
