#include "asm.inc"
/*
 * sigv4.S - AWS Signature Version 4.
 *
 * Every EC2 call the backend makes is signed here, with our own SHA-256 and
 * our own HMAC underneath.  The signed header set is fixed at
 * host;x-amz-content-sha256;x-amz-date - already in the lexicographic order
 * AWS requires, which is what lets this skip a sort.
 *
 * struct sigv4 (see backend/sigv4.inc for the offsets)
 */
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

#define CANON_SZ        8192

        CODE
        .p2align 2

/*
 * sigv4_sign - fill in the Authorization header value for one request.
 *   x0 = struct sigv4 *
 *   out w0 = 0
 */
        .globl  SYM(sigv4_sign)
SYM(sigv4_sign):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x0

/* ---- hash the payload -------------------------------------------------- */
        ldr     x0, [x19, #SV_PAYLOAD]
        ldr     w1, [x19, #SV_PAYLOADLEN]
        LEA     x2, sv_digest
        bl      SYM(sha256)
        LEA     x0, sv_digest
        mov     w1, #32
        ldr     x2, [x19, #SV_HASHOUT]
        bl      SYM(hex_encode)

/* ---- canonical request -------------------------------------------------- */
        LEA     x20, sv_canon
        mov     x0, x20
        ldr     x1, [x19, #SV_METHOD]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_nl
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_PATH]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_nl
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_QUERY]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_nl_host
        bl      SYM(str_copy)           /* "\nhost:" */
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_HOST]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_nl_csha
        bl      SYM(str_copy)           /* "\nx-amz-content-sha256:" */
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_HASHOUT]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_nl_date
        bl      SYM(str_copy)           /* "\nx-amz-date:" */
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_AMZDATE]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_signed_hdrs       /* "\n\nhost;...;x-amz-date\n" */
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_HASHOUT]
        bl      SYM(str_copy)
        mov     x20, x0

        LEA     x0, sv_canon            /* hash it */
        sub     w1, w20, w0
        LEA     x0, sv_canon
        bl      SYM(sha256_len_helper)
        LEA     x0, sv_digest
        mov     w1, #32
        LEA     x2, sv_canonhex
        bl      SYM(hex_encode)

/* ---- string to sign ----------------------------------------------------- */
        LEA     x21, sv_sts
        mov     x0, x21
        LEA     x1, s_algo              /* "AWS4-HMAC-SHA256\n" */
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        ldr     x1, [x19, #SV_AMZDATE]
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        LEA     x1, s_nl
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x22, x21                /* the scope starts here */
        mov     x0, x21
        ldr     x1, [x19, #SV_DATESTAMP]
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        LEA     x1, s_slash
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        ldr     x1, [x19, #SV_REGION]
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        LEA     x1, s_slash
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        ldr     x1, [x19, #SV_SERVICE]
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        LEA     x1, s_aws4_req          /* "/aws4_request" */
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x23, x21                /* scope ends here */
        mov     x0, x21
        LEA     x1, s_nl
        bl      SYM(str_copy)
        mov     x21, x0
        mov     x0, x21
        LEA     x1, sv_canonhex
        bl      SYM(str_copy)
        mov     x21, x0

/* ---- signing key: HMAC chained over date, region, service --------------- */
        LEA     x24, sv_key             /* "AWS4" + secret */
        mov     x0, x24
        LEA     x1, s_aws4
        bl      SYM(str_copy)
        mov     x0, x0
        ldr     x1, [x19, #SV_SECRET]
        bl      SYM(str_copy)
        LEA     x0, sv_key
        bl      SYM(str_len)
        mov     w25, w0

        ldr     x26, [x19, #SV_DATESTAMP]
        mov     x0, x26
        bl      SYM(str_len)            /* w0 = datestamp length */
        mov     w3, w0
        LEA     x0, sv_key
        mov     w1, w25
        mov     x2, x26
        LEA     x4, sv_k1
        bl      SYM(hmac_sha256)

        ldr     x26, [x19, #SV_REGION]
        mov     x0, x26
        bl      SYM(str_len)
        mov     w3, w0
        LEA     x0, sv_k1
        mov     w1, #32
        mov     x2, x26
        LEA     x4, sv_k2
        bl      SYM(hmac_sha256)

        ldr     x26, [x19, #SV_SERVICE]
        mov     x0, x26
        bl      SYM(str_len)
        mov     w3, w0
        LEA     x0, sv_k2
        mov     w1, #32
        mov     x2, x26
        LEA     x4, sv_k1
        bl      SYM(hmac_sha256)

        LEA     x0, sv_k1
        mov     w1, #32
        LEA     x2, s_aws4_request
        mov     w3, #12
        LEA     x4, sv_k2
        bl      SYM(hmac_sha256)

        LEA     x0, sv_sts              /* sign the string to sign */
        bl      SYM(str_len)
        mov     w3, w0
        LEA     x0, sv_k2
        mov     w1, #32
        LEA     x2, sv_sts
        LEA     x4, sv_digest
        bl      SYM(hmac_sha256)
        LEA     x0, sv_digest
        mov     w1, #32
        LEA     x2, sv_sighex
        bl      SYM(hex_encode)

/* ---- Authorization: ... ------------------------------------------------- */
        ldr     x20, [x19, #SV_OUT]
        mov     x0, x20
        LEA     x1, s_auth_head         /* "AWS4-HMAC-SHA256 Credential=" */
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #SV_AKID]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_slash
        bl      SYM(str_copy)
        mov     x20, x0
1:      cmp     x22, x23                /* copy the scope back out verbatim */
        b.hs    2f
        ldrb    w9, [x22], #1
        strb    w9, [x20], #1
        b       1b
2:      strb    wzr, [x20]
        mov     x0, x20
        LEA     x1, s_auth_mid          /* ", SignedHeaders=...Signature=" */
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, sv_sighex
        bl      SYM(str_copy)

        mov     w0, #0
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* sha256 of x0 for w1 bytes into sv_digest - keeps the caller readable */
SYM(sha256_len_helper):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x2, sv_digest
        bl      SYM(sha256)
        ldp     x29, x30, [sp], #16
        ret

        CSTR
s_nl:            .asciz "\n"
s_slash:         .asciz "/"
s_nl_host:       .asciz "\nhost:"
s_nl_csha:       .asciz "\nx-amz-content-sha256:"
s_nl_date:       .asciz "\nx-amz-date:"
s_signed_hdrs:   .asciz "\n\nhost;x-amz-content-sha256;x-amz-date\n"
s_algo:          .asciz "AWS4-HMAC-SHA256\n"
s_aws4_req:      .asciz "/aws4_request"
s_aws4:          .asciz "AWS4"
s_aws4_request:  .asciz "aws4_request"
s_auth_head:     .asciz "AWS4-HMAC-SHA256 Credential="
s_auth_mid:      .asciz ", SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="

        BSS
        .p2align 4
sv_canon:       .space CANON_SZ
sv_sts:         .space 1024
sv_key:         .space 256
sv_canonhex:    .space 72
sv_sighex:      .space 72
sv_digest:      .space 32
sv_k1:          .space 32
sv_k2:          .space 32
