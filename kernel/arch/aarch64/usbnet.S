#include "asm.inc"
/*
 * usbnet.S - a network over the USB controller.
 *
 * The other half of what a bare-metal machine needs. The keyboard came off the
 * same controller; this is the adapter, and behind it the IP and TCP this
 * kernel already has. A machine with both can be typed at and can reach a
 * backend, which is the whole of what it takes to develop on itself.
 *
 * <h2>RNDIS, and why that one</h2>
 *
 * There are three ways a USB adapter can present a network. CDC-ECM is the
 * standard and the tidiest. Vendor-specific parts - ASIX, Realtek - are what
 * most cheap dongles are, and each is its own driver. RNDIS is Microsoft's,
 * and it is what a phone offers when it shares its connection over a cable.
 *
 * RNDIS is the one implemented here for a reason this project keeps returning
 * to: it is the one that can be tested. QEMU's usb-net speaks it, so this can
 * be written against something that answers rather than against a
 * specification and a hope. It is also independently the most likely thing to
 * be plugged into a laptop that has no network - a phone.
 *
 * <h2>Two interfaces, and only one of them carries anything</h2>
 *
 * The adapter presents a control interface - class 2, subclass 2, protocol 255,
 * which is the signature - and a data interface of class 10 with a pair of bulk
 * endpoints. Commands go to the control interface as ordinary control
 * transfers with the message inside them; frames go over the bulk pair. The
 * interrupt endpoint on the control interface is how the device says an answer
 * is ready, and is not used here: asking for the answer works whether or not
 * the notification was seen, and one fewer endpoint is one fewer thing to be
 * wrong.
 *
 * <h2>Every frame is wrapped</h2>
 *
 * RNDIS does not put Ethernet frames on the wire. It puts messages, and a
 * frame travels inside one with a forty-four byte header saying where in the
 * message the frame starts and how long it is. Both directions. A driver that
 * forgot the header would send something the other end discards and would read
 * the header as the first forty-four bytes of every frame it received.
 */

#define RNDIS_PACKET    0x00000001
#define RNDIS_INIT      0x00000002
#define RNDIS_INIT_CMPLT 0x80000002
#define RNDIS_QUERY     0x00000004
#define RNDIS_QUERY_CMPLT 0x80000004
#define RNDIS_SET       0x00000005
#define RNDIS_SET_CMPLT 0x80000005

#define OID_PACKET_FILTER   0x0001010E
#define OID_STATION_ADDRESS 0x01010102

#define FILTER_ALL      0x0000000F      /* directed, multicast, all-multicast,
                                           broadcast: everything this needs */
#define PKT_HDR         44
#define NET_MAX         1600

        CODE
        .p2align 2

/*
 * usbnet_start - w0 = the slot the adapter is on, x1 = its configuration
 *   descriptor, w2 = how many bytes of it.
 *   out w0 = 0 if the adapter is ready to carry frames, -1 if it is not.
 */
        .globl  SYM(usbnet_start)
SYM(usbnet_start):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

/*
 * Walk the configuration for the data interface and its two bulk endpoints.
 * Class ten is CDC Data and there is one of it; the endpoints that follow it
 * are the pair, and their directions are in the top bit of their addresses.
 */
        mov     w0, #1                  /* looking for the bulk endpoints */
        bl      un_step
        mov     w22, #0                 /* the bulk endpoint carrying to us */
        mov     w23, #0                 /* and the one carrying to it */
        mov     w24, #0                 /* how big its packets are */
        mov     w25, #0                 /* are we inside the data interface? */
        mov     w26, #0                 /* the configuration's own value */
        ldrb    w26, [x20, #5]
        mov     w27, #9
1:      cmp     w27, w21
        b.hs    5f
        add     x9, x20, w27, uxtw
        ldrb    w10, [x9]
        cbz     w10, 5f
        ldrb    w11, [x9, #1]

        cmp     w11, #4                         /* an interface */
        b.ne    2f
        ldrb    w12, [x9, #5]
        cmp     w12, #10                        /* CDC data */
        cset    w25, eq
        b       4f

2:      cmp     w11, #5                         /* an endpoint */
        b.ne    4f
        cbz     w25, 4f
        ldrb    w12, [x9, #3]
        and     w12, w12, #3
        cmp     w12, #2                         /* bulk, and nothing else */
        b.ne    4f
        ldrb    w12, [x9, #2]
        ldrb    w13, [x9, #4]
        ldrb    w14, [x9, #5]
        orr     w24, w13, w14, lsl #8
        tbz     w12, #7, 3f
        mov     w22, w12
        b       4f
3:      mov     w23, w12
4:      add     w27, w27, w10
        b       1b
5:      cbz     w22, .Lun_fail
        cbz     w23, .Lun_fail
        mov     w0, #2                  /* choosing the configuration */
        bl      un_step

/* Choose the configuration, without which it has no endpoints at all. */
        LEA     x9, SYM(xhci_req)
        strb    wzr, [x9]
        mov     w10, #9                         /* SET_CONFIGURATION */
        strb    w10, [x9, #1]
        strb    w26, [x9, #2]
        strb    wzr, [x9, #3]
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        strb    wzr, [x9, #6]
        strb    wzr, [x9, #7]
        mov     w0, w19
        mov     x1, #0
        mov     w2, #0
        bl      SYM(xhci_control)
        cmn     w0, #1
        b.eq    .Lun_fail

/*
 * Describe both endpoints at once. Configure Endpoint replaces what the
 * controller knows rather than adding to it, so sending them one at a time
 * would leave the second command undoing the first.
 */
        mov     w0, #3                  /* describing the endpoints */
        bl      un_step
        bl      SYM(xhci_beginctx)
        mov     w0, w19
        mov     w1, w22
        mov     w2, #6                          /* bulk in: the types are
                                                   numbered by direction, and
                                                   six is the one that carries
                                                   to us - two is the other */
        mov     w3, w24
        LEA     x4, SYM(xhci_bulkin)
        bl      SYM(xhci_addep)
        LEA     x9, SYM(usbnet_indci)
        str     w0, [x9]
        mov     w20, w0

        mov     w0, w19
        mov     w1, w23
        mov     w2, #2                          /* bulk out */
        mov     w3, w24
        LEA     x4, SYM(xhci_bulkout)
        bl      SYM(xhci_addep)
        LEA     x9, SYM(usbnet_outdci)
        str     w0, [x9]

        cmp     w0, w20                         /* whichever index is higher */
        csel    w1, w0, w20, hi
        mov     w0, w19
        bl      SYM(xhci_slotctx)
        mov     w0, w19
        bl      SYM(xhci_applyctx)
        cmn     w0, #1
        b.eq    .Lun_fail

        LEA     x9, SYM(usbnet_slot)
        str     w19, [x9]

/*
 * Now the protocol. Initialise, then say which frames to pass up: without a
 * filter the adapter receives nothing, which is not a fault anybody can see -
 * the link is up, the endpoint is armed, and nothing ever arrives.
 */
        mov     w0, #4                  /* initialising the protocol */
        bl      un_step
        bl      usbnet_init
        cmn     w0, #1
        b.eq    .Lun_fail
        mov     w0, #5                  /* setting the packet filter */
        bl      un_step
        bl      usbnet_filter
        cmn     w0, #1
        b.eq    .Lun_fail
        mov     w0, #6                  /* asking its hardware address */
        bl      un_step
        bl      usbnet_address
        cmn     w0, #1
        b.eq    .Lun_fail

        mov     w0, #0
        bl      un_step
        mov     w0, #0
        b       .Lun_out
.Lun_fail:
        LEA     x9, SYM(usbnet_slot)
        str     wzr, [x9]
        mov     w0, #-1
.Lun_out:
        ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * usbnet_msg - x0 = a message to send, w1 = its length. out w0 = 0 or -1.
 *
 * A control message travels inside a control transfer, which is what
 * "encapsulated" means: the request says only that a message follows and how
 * long it is, and the message itself is the data stage.
 */
usbnet_msg:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     w20, w1
        LEA     x9, SYM(xhci_req)
        mov     w10, #0x21                      /* OUT, class, to the interface */
        strb    w10, [x9]
        strb    wzr, [x9, #1]                   /* SEND_ENCAPSULATED_COMMAND */
        strb    wzr, [x9, #2]
        strb    wzr, [x9, #3]
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        strb    w20, [x9, #6]
        lsr     w10, w20, #8
        strb    w10, [x9, #7]
        LEA     x9, SYM(usbnet_slot)
        ldr     w0, [x9]
        mov     x1, x19
        mov     w2, w20
        bl      SYM(xhci_control)
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* usbnet_reply - read whatever the device made of the last message. */
usbnet_reply:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, SYM(xhci_req)
        mov     w10, #0xA1                      /* IN, class, from the interface */
        strb    w10, [x9]
        mov     w10, #1                         /* GET_ENCAPSULATED_RESPONSE */
        strb    w10, [x9, #1]
        strb    wzr, [x9, #2]
        strb    wzr, [x9, #3]
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        mov     w10, #0x80
        strb    w10, [x9, #6]
        strb    wzr, [x9, #7]
        LEA     x9, SYM(usbnet_slot)
        ldr     w0, [x9]
        LEA     x1, un_reply
        mov     w2, #128
        bl      SYM(xhci_control)
        ldp     x29, x30, [sp], #16
        ret

/* usbnet_init - the first message, which settles what each side can do. */
usbnet_init:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, un_msg
        mov     x0, x9
        mov     x1, #64
        bl      un_zero
        LEA     x9, un_msg
        mov     w10, #RNDIS_INIT
        str     w10, [x9]
        mov     w10, #24
        str     w10, [x9, #4]                   /* how long this message is */
        mov     w10, #1
        str     w10, [x9, #8]                   /* something to match a reply to */
        str     w10, [x9, #12]                  /* the version we speak */
        str     wzr, [x9, #16]
        mov     w10, #0x4000
        str     w10, [x9, #20]                  /* the biggest transfer we take */
        mov     x0, x9
        mov     w1, #24
        bl      usbnet_msg
        cmn     w0, #1
        b.eq    9f
        bl      usbnet_reply
        cmn     w0, #1
        b.eq    9f
        LEA     x9, un_reply
        ldr     w0, [x9]
        movz    w10, #0x8000, lsl #16
        movk    w10, #0x0002
        cmp     w0, w10
        b.ne    9f
        ldr     w0, [x9, #12]                   /* what it made of the request */
        cbnz    w0, 9f
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x29, x30, [sp], #16
        ret

/* usbnet_filter - say which frames to pass up, without which none are. */
usbnet_filter:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, un_msg
        mov     x0, x9
        mov     x1, #64
        bl      un_zero
        LEA     x9, un_msg
        mov     w10, #RNDIS_SET
        str     w10, [x9]
        mov     w10, #32
        str     w10, [x9, #4]
        mov     w10, #2
        str     w10, [x9, #8]
        movz    w10, #0x0001, lsl #16
        movk    w10, #0x010E
        str     w10, [x9, #12]                  /* which setting */
        mov     w10, #4
        str     w10, [x9, #16]                  /* four bytes of it */
        mov     w10, #20
        str     w10, [x9, #20]                  /* which begin here */
        str     wzr, [x9, #24]
        mov     w10, #FILTER_ALL
        str     w10, [x9, #28]
        mov     x0, x9
        mov     w1, #32
        bl      usbnet_msg
        cmn     w0, #1
        b.eq    9f
        bl      usbnet_reply
        cmn     w0, #1
        b.eq    9f
        LEA     x9, un_reply
        ldr     w0, [x9, #12]
        cbnz    w0, 9f
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * usbnet_address - ask the adapter what hardware address it has.
 *
 * Not a nicety. Every frame this machine sends carries it, and the DHCP server
 * hands out a lease against it - so an adapter whose address this kernel
 * guessed would be given a lease belonging to somebody else, or none.
 */
usbnet_address:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, un_msg
        mov     x0, x9
        mov     x1, #64
        bl      un_zero
        LEA     x9, un_msg
        mov     w10, #RNDIS_QUERY
        str     w10, [x9]
        mov     w10, #28
        str     w10, [x9, #4]
        mov     w10, #3
        str     w10, [x9, #8]
        movz    w10, #0x0101, lsl #16
        movk    w10, #0x0102
        str     w10, [x9, #12]                  /* its station address */
/*
 * A query carries no buffer of its own, so both its length and its offset are
 * zero. Naming an offset for a buffer that is not there is not harmless: the
 * device reads it, looks for input that does not exist, and refuses the whole
 * request with a status this end can only report as "no".
 */
        str     wzr, [x9, #16]
        str     wzr, [x9, #20]
        str     wzr, [x9, #24]
        mov     x0, x9
        mov     w1, #28
        bl      usbnet_msg
        cmn     w0, #1
        b.eq    9f
        bl      usbnet_reply
        cmn     w0, #1
        b.eq    9f
        LEA     x9, un_reply
        ldr     w0, [x9, #12]
        cbnz    w0, 9f
/*
 * Length first, then offset - in that order in the reply, which is the
 * opposite of the order they are in the request. Read the other way round, the
 * offset is checked for being at least six and the length is used to find the
 * answer, which lands somewhere plausible inside the reply and yields six
 * bytes of something that is not an address.
 */
        ldr     w11, [x9, #16]                  /* how long the answer is */
        ldr     w10, [x9, #20]                  /* and where, from byte eight */
        cmp     w11, #6
        b.lo    9f
        add     x10, x10, #8
        cmp     x10, #120                       /* inside what was read back */
        b.hi    9f
        add     x10, x9, w10, uxtw
        LEA     x11, SYM(usbnet_mac)
        mov     w12, #0
1:      cmp     w12, #6
        b.hs    2f
        ldrb    w13, [x10, w12, uxtw]
        strb    w13, [x11, w12, uxtw]
        add     w12, w12, #1
        b       1b
2:      mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * usbnet_send - x0 = an Ethernet frame, w1 = its length. out w0 = 0 or -1.
 *
 * Wrapped, because RNDIS carries messages rather than frames: forty-four bytes
 * saying what follows, then the frame. The offset in the header is counted
 * from the header's own ninth byte rather than from its start, which is the
 * kind of detail that produces a link where everything is sent and nothing is
 * understood.
 */
        .globl  SYM(usbnet_send)
SYM(usbnet_send):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     w20, w1

        LEA     x9, SYM(usbnet_slot)
        ldr     w9, [x9]
        cbz     w9, 9f
        cmp     w20, #(NET_MAX - PKT_HDR)
        b.hi    9f

        LEA     x0, un_tx
        mov     x1, #PKT_HDR
        bl      un_zero
        LEA     x9, un_tx
        mov     w10, #RNDIS_PACKET
        str     w10, [x9]
        add     w10, w20, #PKT_HDR
        str     w10, [x9, #4]                   /* the whole message */
        mov     w10, #(PKT_HDR - 8)
        str     w10, [x9, #8]                   /* where the frame starts */
        str     w20, [x9, #12]                  /* and how long it is */

        add     x9, x9, #PKT_HDR
        mov     w10, #0
1:      cmp     w10, w20
        b.hs    2f
        ldrb    w11, [x19, w10, uxtw]
        strb    w11, [x9, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:
        LEA     x9, SYM(usbnet_slot)
        ldr     w0, [x9]
        LEA     x9, SYM(usbnet_outdci)
        ldr     w1, [x9]
        LEA     x2, un_tx
        add     w3, w20, #PKT_HDR
        LEA     x4, SYM(xhci_bulkout)
        LEA     x5, SYM(xhci_outpos)
        bl      SYM(xhci_bulk)
        cmn     w0, #1
        b.eq    9f
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * usbnet_recv - x0 = where to put a frame, w1 = how much room.
 *   out w0 = the frame's length, or -1 if nothing came.
 */
        .globl  SYM(usbnet_recv)
SYM(usbnet_recv):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     w20, w1

        LEA     x9, SYM(usbnet_slot)
        ldr     w9, [x9]
        cbz     w9, 9f

/* Keep one receive outstanding, so a frame that arrives has somewhere to go. */
        LEA     x9, un_armed
        ldr     w9, [x9]
        cbnz    w9, 1f
        bl      un_arm
1:
        bl      SYM(xhci_pump)
        LEA     x9, SYM(usbnet_indci)
        ldr     w0, [x9]
        bl      SYM(xhci_epdone)
        cmn     w0, #1
        b.eq    9f

        LEA     x9, un_armed
        str     wzr, [x9]
/*
 * What came back is the residue - how much of the buffer went unused - so the
 * length is what is left of it, and a completion code that is neither success
 * nor a short packet means nothing arrived worth reading.
 */
        lsr     w10, w0, #24
        and     w11, w0, #0xFFFFFF
        cmp     w10, #1
        b.eq    2f
        cmp     w10, #13
        b.ne    8f
2:      mov     w12, #NET_MAX
        sub     w12, w12, w11                   /* how many bytes arrived */
        cmp     w12, #PKT_HDR
        b.lo    8f

        LEA     x9, un_rx
        ldr     w10, [x9]
        cmp     w10, #RNDIS_PACKET
        b.ne    8f
        ldr     w11, [x9, #8]                   /* where the frame is */
        ldr     w12, [x9, #12]                  /* and how long */
        cbz     w12, 8f
        cmp     w12, w20
        b.hi    8f
        add     x11, x11, #8
        add     x11, x9, w11, uxtw
        mov     w13, #0
3:      cmp     w13, w12
        b.hs    4f
        ldrb    w14, [x11, w13, uxtw]
        strb    w14, [x19, w13, uxtw]
        add     w13, w13, #1
        b       3b
4:      mov     w19, w12
        bl      un_arm                          /* ready for the next one */
        mov     w0, w19
        b       10f

8:      bl      un_arm
9:      mov     w0, #-1
10:     ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* un_arm - hand the adapter somewhere to put the next frame. */
un_arm:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, SYM(usbnet_slot)
        ldr     w0, [x9]
        cbz     w0, 8f
        LEA     x9, SYM(usbnet_indci)
        ldr     w1, [x9]
        LEA     x2, un_rx
        mov     w3, #NET_MAX
        LEA     x4, SYM(xhci_bulkin)
        LEA     x5, SYM(xhci_inpos)
        bl      SYM(xhci_bulkq)
        LEA     x9, un_armed
        mov     w10, #1
        str     w10, [x9]
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * un_step - w0 = which stage is being attempted, kept for the report.
 *
 * Bringing an adapter up is six things and each fails differently: no bulk
 * endpoints is the wrong interface, a configuration that will not take is a
 * device in a state nobody expected, an initialise that is refused is a
 * protocol disagreement, and a filter that fails is a link that comes up and
 * carries nothing. Saying which beats saying that it did not work.
 */
un_step:
        LEA     x9, SYM(usbnet_stage)
        str     w0, [x9]
        ret

un_zero:
        add     x2, x0, x1
1:      cmp     x0, x2
        b.hs    2f
        str     xzr, [x0]
        add     x0, x0, #8
        b       1b
2:      ret

        BSS
        .p2align 3
        .globl  SYM(usbnet_slot)
        .globl  SYM(usbnet_indci)
        .globl  SYM(usbnet_outdci)
        .globl  SYM(usbnet_mac)
        .globl  SYM(usbnet_stage)
SYM(usbnet_slot):   .space 4
SYM(usbnet_indci):  .space 4
SYM(usbnet_outdci): .space 4
SYM(usbnet_mac):    .space 8
SYM(usbnet_stage):  .space 4
un_armed:           .space 4
        .p2align 6
un_msg:    .space 64
un_reply:  .space 128
un_tx:     .space NET_MAX
un_rx:     .space NET_MAX
