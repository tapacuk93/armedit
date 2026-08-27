#include "asm.inc"
#include "account.inc"
/*
 * aws.S - provision and deprovision the account's instance.
 *
 * EC2's query API: a form-encoded POST, signed with SigV4 (backend/sigv4.S),
 * answered in XML.  What we ask for is deliberately small - one instance,
 * running a minimal Linux, with Docker brought up by user-data - because the
 * editor only needs somewhere to run things, and every instance is billed to
 * the account that asked for it.
 *
 * Transport note: this speaks plain HTTP to whatever address
 * ARMEDIT_AWS_ADDR names, which today means an endpoint that terminates TLS
 * for us or a local EC2-compatible one.  Reaching ec2.amazonaws.com directly
 * needs the TLS client, which is the next milestone - see the README.  The
 * signing, the request and the parsing are all real.
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

#define SV_AKID         0
#define SV_SECRET       8
#define SV_REGION       16
#define SV_SERVICE      24
#define SV_METHOD       32
#define SV_PATH         40
#define SV_QUERY        48
#define SV_HOST         56
#define SV_PAYLOAD      64
#define SV_PAYLOADLEN   72
#define SV_AMZDATE      80
#define SV_DATESTAMP    88
#define SV_OUT          96
#define SV_OUTCAP       104
#define SV_HASHOUT      112

#define AWS_BODY_SZ     8192
#define AWS_RESP_SZ     32768

        CODE
        .p2align 2

/*
 * aws_call - sign and send one EC2 query request.
 *   x0 = account, x1 = form body
 *   out w0 = response length, or -1.  The response is left in aws_resp.
 */
aws_call:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1

        LEA     x0, aws_amzdate         /* AWS checks the clock */
        LEA     x1, aws_datestamp
        bl      SYM(time_utc)

        LEA     x0, aws_host            /* ec2.<region>.amazonaws.com */
        LEA     x1, s_ec2_prefix
        bl      SYM(str_copy)
        add     x1, x19, #ACCT_REGION
        bl      SYM(str_copy)
        LEA     x1, s_ec2_suffix
        bl      SYM(str_copy)

        LEA     x21, aws_sv             /* everything the signer needs */
        add     x0, x19, #ACCT_AKID
        str     x0, [x21, #SV_AKID]
        add     x0, x19, #ACCT_SECRET
        str     x0, [x21, #SV_SECRET]
        add     x0, x19, #ACCT_REGION
        str     x0, [x21, #SV_REGION]
        LEA     x0, s_service
        str     x0, [x21, #SV_SERVICE]
        LEA     x0, s_post
        str     x0, [x21, #SV_METHOD]
        LEA     x0, s_slash
        str     x0, [x21, #SV_PATH]
        LEA     x0, s_empty
        str     x0, [x21, #SV_QUERY]
        LEA     x0, aws_host
        str     x0, [x21, #SV_HOST]
        str     x20, [x21, #SV_PAYLOAD]
        mov     x0, x20
        bl      SYM(str_len)
        mov     w22, w0
        str     w22, [x21, #SV_PAYLOADLEN]
        LEA     x0, aws_amzdate
        str     x0, [x21, #SV_AMZDATE]
        LEA     x0, aws_datestamp
        str     x0, [x21, #SV_DATESTAMP]
        LEA     x0, aws_auth
        str     x0, [x21, #SV_OUT]
        mov     w0, #1024
        str     w0, [x21, #SV_OUTCAP]
        LEA     x0, aws_payhash
        str     x0, [x21, #SV_HASHOUT]
        mov     x0, x21
        bl      SYM(sigv4_sign)

        LEA     x0, aws_hdrs            /* the three signed headers, plus the
                                           content type EC2 expects */
        LEA     x1, s_hdr_ctype
        bl      SYM(str_copy)
        LEA     x1, s_hdr_date
        bl      SYM(str_copy)
        LEA     x1, aws_amzdate
        bl      SYM(str_copy)
        LEA     x1, s_hdr_sha
        bl      SYM(str_copy)
        LEA     x1, aws_payhash
        bl      SYM(str_copy)
        LEA     x1, s_hdr_auth
        bl      SYM(str_copy)
        LEA     x1, aws_auth
        bl      SYM(str_copy)
        LEA     x1, s_crlf
        bl      SYM(str_copy)

        LEA     x0, s_env_addr          /* where do we send it? */
        bl      SYM(env_get)
        mov     x23, x0
        cbnz    x23, 1f
        LEA     x23, s_addr_default
1:      LEA     x24, aws_req
        mov     x0, x23
        add     x1, x24, #REQ_IP
        add     x2, x24, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbnz    w0, #31, .Laws_fail

        LEA     x0, s_post
        str     x0, [x24, #REQ_METHOD]
        LEA     x0, s_slash
        str     x0, [x24, #REQ_PATH]
        LEA     x0, aws_host            /* Host must match what was signed */
        str     x0, [x24, #REQ_HOST]
        LEA     x0, aws_hdrs
        str     x0, [x24, #REQ_HDRS]
        str     x20, [x24, #REQ_BODY]
        str     w22, [x24, #REQ_BODYLEN]
        LEA     x0, aws_resp
        str     x0, [x24, #REQ_OUT]
        mov     w0, #AWS_RESP_SZ
        str     w0, [x24, #REQ_OUTCAP]
        mov     x0, x24
        bl      SYM(http_request)
        b       .Laws_out
.Laws_fail:
        mov     w0, #-1
.Laws_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * aws_provision - bring up this account's instance.
 *   x0 = account; out w0 = 0 on success (instance id stored on the account),
 *   -1 otherwise.  Idempotent: an account that already has one keeps it.
 */
        .globl  SYM(aws_provision)
SYM(aws_provision):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0

        add     x0, x19, #ACCT_INSTANCE
        ldrb    w9, [x0]
        cbz     w9, 1f
        mov     w0, #0                  /* already running */
        b       .Lprov_out
1:
        LEA     x0, s_userdata          /* cloud-init: install and start Docker */
        bl      SYM(str_len)
        mov     w1, w0
        LEA     x0, s_userdata
        LEA     x2, aws_b64
        bl      SYM(base64_encode)
        LEA     x0, aws_b64             /* base64 is not form-safe as-is */
        LEA     x1, aws_b64enc
        bl      url_encode

        LEA     x20, aws_body           /* x20 walks the body as it grows:
                                           str_len's result cannot survive the
                                           LEA that would follow it */
        mov     x0, x20
        LEA     x1, s_run_head
        bl      SYM(str_copy)
        mov     x20, x0

        LEA     x0, s_env_ami
        bl      SYM(env_get)
        mov     x21, x0
        cbnz    x21, 2f
        mov     w0, #-2                 /* no AMI configured: say so plainly */
        b       .Lprov_out
2:      mov     x0, x20
        mov     x1, x21
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_run_type
        bl      SYM(str_copy)
        mov     x20, x0

        LEA     x0, s_env_type
        bl      SYM(env_get)
        mov     x22, x0
        cbnz    x22, 3f
        LEA     x22, s_type_default
3:      mov     x0, x20
        mov     x1, x22
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_run_tail
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, aws_b64enc
        bl      SYM(str_copy)

        mov     x0, x19
        LEA     x1, aws_body
        bl      aws_call
        cmp     w0, #0
        b.le    .Lprov_fail

        LEA     x0, aws_resp            /* <instanceId>i-...</instanceId> */
        LEA     x1, s_tag_instance
        bl      SYM(str_find)
        cbz     x0, .Lprov_fail
        add     x1, x19, #ACCT_INSTANCE
        mov     w2, #0
4:      ldrb    w3, [x0], #1
        cbz     w3, 5f
        cmp     w3, #'<'
        b.eq    5f
        strb    w3, [x1, w2, uxtw]
        add     w2, w2, #1
        cmp     w2, #48
        b.lo    4b
5:      strb    wzr, [x1, w2, uxtw]
        mov     w0, #0
        b       .Lprov_out
.Lprov_fail:
        mov     w0, #-1
.Lprov_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * aws_deprovision - terminate this account's instance and forget it.
 *   x0 = account; out w0 = 0 on success, -1 otherwise
 */
        .globl  SYM(aws_deprovision)
SYM(aws_deprovision):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        add     x0, x19, #ACCT_INSTANCE
        ldrb    w9, [x0]
        cbnz    w9, 1f
        mov     w0, #0                  /* nothing to tear down */
        b       .Ldeprov_out
1:      LEA     x0, aws_body
        LEA     x1, s_term_head
        bl      SYM(str_copy)
        add     x1, x19, #ACCT_INSTANCE
        bl      SYM(str_copy)
        mov     x0, x19
        LEA     x1, aws_body
        bl      aws_call
        cmp     w0, #0
        b.le    .Ldeprov_fail
        add     x0, x19, #ACCT_INSTANCE
        strb    wzr, [x0]
        mov     w0, #0
        b       .Ldeprov_out
.Ldeprov_fail:
        mov     w0, #-1
.Ldeprov_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * url_encode - x0 = source, x1 = destination.  Percent-encodes everything
 * that is not unreserved, which for our purposes is the base64 padding and
 * the two non-alphanumeric base64 digits.
 */
url_encode:
        LEA     x4, hexdigits
1:      ldrb    w2, [x0], #1
        cbz     w2, 9f
        sub     w3, w2, #'0'            /* 0-9 */
        cmp     w3, #9
        b.ls    2f
        sub     w3, w2, #'A'            /* A-Z */
        cmp     w3, #25
        b.ls    2f
        sub     w3, w2, #'a'            /* a-z */
        cmp     w3, #25
        b.ls    2f
        cmp     w2, #'-'
        b.eq    2f
        cmp     w2, #'_'
        b.eq    2f
        cmp     w2, #'.'
        b.eq    2f
        cmp     w2, #'~'
        b.eq    2f
        mov     w5, #'%'                /* everything else: %XX */
        strb    w5, [x1], #1
        lsr     w5, w2, #4
        ldrb    w5, [x4, w5, uxtw]
        strb    w5, [x1], #1
        and     w5, w2, #0xF
        ldrb    w5, [x4, w5, uxtw]
        strb    w5, [x1], #1
        b       1b
2:      strb    w2, [x1], #1
        b       1b
9:      strb    wzr, [x1]
        ret

        RODATA
hexdigits:      .ascii "0123456789ABCDEF"

        CSTR
s_env_addr:     .asciz "ARMEDIT_AWS_ADDR"
s_addr_default: .asciz "127.0.0.1:4566"
s_env_ami:      .asciz "ARMEDIT_AMI"
s_env_type:     .asciz "ARMEDIT_INSTANCE_TYPE"
s_type_default: .asciz "t4g.small"
s_service:      .asciz "ec2"
s_post:         .asciz "POST"
s_slash:        .asciz "/"
s_empty:        .asciz ""
s_crlf:         .asciz "\r\n"
s_ec2_prefix:   .asciz "ec2."
s_ec2_suffix:   .asciz ".amazonaws.com"
s_hdr_ctype:    .asciz "Content-Type: application/x-www-form-urlencoded; charset=utf-8\r\n"
s_hdr_date:     .asciz "x-amz-date: "
s_hdr_sha:      .asciz "\r\nx-amz-content-sha256: "
s_hdr_auth:     .asciz "\r\nAuthorization: "
s_tag_instance: .asciz "<instanceId>"
s_run_head:     .asciz "Action=RunInstances&Version=2016-11-15&MinCount=1&MaxCount=1&ImageId="
s_run_type:     .asciz "&InstanceType="
s_run_tail:     .asciz "&UserData="
s_term_head:    .asciz "Action=TerminateInstances&Version=2016-11-15&InstanceId.1="
s_userdata:     .asciz "#!/bin/bash\ndnf install -y docker\nsystemctl enable --now docker\ndocker run -d --restart=always --name armedit alpine:3 sleep infinity\n"

        BSS
        .p2align 4
aws_req:        .space 80
aws_sv:         .space 128
aws_body:       .space AWS_BODY_SZ
aws_hdrs:       .space 2048
aws_resp:       .space AWS_RESP_SZ
aws_auth:       .space 1024
aws_host:       .space 128
aws_amzdate:    .space 24
aws_datestamp:  .space 16
aws_payhash:    .space 72
aws_b64:        .space 1024
aws_b64enc:     .space 3072
