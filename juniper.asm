; =============================================================================
;  juniper — a textured 3D raycasting engine in x86-64 assembly
;
;  Linux, NASM, no libc. Renders straight into the terminal using 24-bit
;  colour and the upper-half-block glyph (two square pixels per cell).
;
;  Controls:  W/S, Up/Down      move forward / back
;             A/D               strafe
;             J/L, Left/Right   turn
;             M                 toggle minimap
;             Q, Esc, Ctrl-C    quit
;
;  Terminals with the kitty keyboard protocol (kitty, foot, WezTerm, Ghostty,
;  Alacritty, ...) report key releases, so movement is smooth while a key is
;  held. Elsewhere it falls back to one step per key event (autorepeat).
;
;  Build:     nasm -f elf64 juniper.asm -o juniper.o && ld juniper.o -o juniper
; =============================================================================

bits 64
default rel

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_POLL    7
%define SYS_IOCTL   16
%define SYS_EXIT    60
%define SYS_CLOCK_GETTIME 228

%define TCGETS      0x5401
%define TCSETS      0x5402
%define TIOCGWINSZ  0x5413

MAX_W       equ 480                 ; framebuffer limits (pixels)
MAX_H       equ 270                 ; must be even
TEX_SIZE    equ 64
TEX_PIX     equ TEX_SIZE*TEX_SIZE
NUM_TEX     equ 7                   ; 0-3 walls, 4-5 floor, 6 ceiling
MAP_W       equ 24
MAP_H       equ 24
OUTBUF_SIZE equ 4*1024*1024
INBUF_SIZE  equ 256

TICK_NS     equ 16666667            ; held-key movement runs at 60 Hz
MAX_TICKS   equ 15
KBD_FLAGS   equ 1|2|8               ; kitty: disambiguate, event types, all keys

K_FWD       equ 1                   ; held key mask
K_BACK      equ 2
K_SL        equ 4
K_SR        equ 8
K_TL        equ 16
K_TR        equ 32

; shade the 0x00RRGGBB colour in a 32-bit register by xmm15 (words, 0..256)
; requires xmm14 = 0, clobbers xmm0
%macro SHADE 1
    movd        xmm0, %1
    punpcklbw   xmm0, xmm14
    pmullw      xmm0, xmm15
    psrlw       xmm0, 8
    packuswb    xmm0, xmm0
    movd        %1, xmm0
%endmacro

; ----------------------------------------------------------------------------
section .data
; ----------------------------------------------------------------------------

align 16
sign_mask:  dq 0x8000000000000000, 0x8000000000000000
abs_mask:   dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
f_margin2:  dq 0.2, 0.2                 ; collision radius

f_one:      dq 1.0
f_half:     dq 0.5
f_tex:      dq 64.0
f_256:      dq 256.0
f_fogk:     dq 13.0                     ; shade drop per unit of distance
f_eps:      dq 0.001
f_lmin:     dq 0.5                      ; camera plane half-width clamp
f_lmax:     dq 1.2
f_move:     dq 0.12
f_nmove:    dq -0.12
f_rotc:     dq 0.9968017063026194       ; cos(0.08)
f_rots:     dq 0.0799146939691727       ; sin(0.08)
f_nrots:    dq -0.0799146939691727
f_tmove:    dq 0.06                     ; per 60 Hz tick: 3.6 units/s
f_ntmove:   dq -0.06
f_trotc:    dq 0.9992001066609779       ; cos(0.04): 2.4 rad/s
f_trots:    dq 0.03998933418663416      ; sin(0.04)
f_ntrots:   dq -0.03998933418663416

; player state
posX:       dq 6.5
posY:       dq 9.5
dirX:       dq 1.0
dirY:       dq 0.0

rng:        dd 0x2545F491

map_colors: dd 0x000000, 0xB04030, 0x7080A0, 0x9A6A3A, 0x3A9A4A

tex_jt:     dq tg_brick, tg_stone, tg_wood, tg_moss, tg_floor_a, tg_floor_b, tg_ceil

; world map, row-major [y][x]; digits are converted to bytes at startup
map:
    db "111111111111111111111111"
    db "100000000000000000000001"
    db "100000000000000000000001"
    db "100022220000003333300001"
    db "100020020000003000300001"
    db "100020020000003000300001"
    db "100020000000000000300001"
    db "100022220000003303300001"
    db "100000000000000000000001"
    db "100000000040400000000001"
    db "100000000000000000000001"
    db "111110111000000004444441"
    db "100000001000000004000001"
    db "100000001000000004000001"
    db "100300001000000000000001"
    db "100000001000000004000001"
    db "100000001000040004000001"
    db "111011111000000004440441"
    db "100000000000000000000001"
    db "100000000222022200000001"
    db "100000000200000200000001"
    db "100030000200000200003001"
    db "100000000222222200000001"
    db "111111111111111111111111"
%if ($ - map) != MAP_W*MAP_H
  %error "map size mismatch"
%endif

s_init:     db 27,"[?1049h",27,"[?25l",27,"[2J"
            db 27,"[>11u",27,"[?u"          ; kitty keyboard: push flags, query
            db 27,"[?1004h"                 ; focus reports
s_init_len  equ $ - s_init
s_kbd_off:  db 27,"[<u",27,"[?1004l",27,"[c" ; pop flags (same screen), then
s_kbd_off_len equ $ - s_kbd_off             ; DA1 to flush stray key events
s_fini:     db 27,"[0m",27,"[2J",27,"[?25h",27,"[?1049l"
s_fini_len  equ $ - s_fini
s_clear:    db 27,"[0m",27,"[2J"
s_clear_len equ $ - s_clear
s_fpre:     db 27,"[?2026h",27,"[H"         ; begin synchronized update, home
s_fpre_len  equ $ - s_fpre
s_fpost:    db 27,"[?2026l",27,"[c"         ; end update, then ask for DA1:
s_fpost_len equ $ - s_fpost                 ; the reply means the frame is drawn
s_notty:    db "juniper: stdin must be a terminal",10
s_notty_len equ $ - s_notty

; ----------------------------------------------------------------------------
section .bss
; ----------------------------------------------------------------------------

alignb 16
termios_orig:   resb 64
termios_raw:    resb 64
winsz:          resw 4
scr_w:          resd 1              ; framebuffer size in pixels
scr_h:          resd 1
planeX:         resq 1
planeY:         resq 1
show_map:       resb 1
dirty:          resb 1
pending:        resb 1              ; frame sent, terminal hasn't acked yet
pend_reads:     resb 1              ; reads spent waiting for that ack
kitty:          resb 1              ; terminal reports key releases
keys:           resb 1              ; K_* currently held
latch:          resb 1              ; K_* pressed since the last tick
ticking:        resb 1
csi_priv:       resb 1
alignb 8
last_tick:      resq 1
ts:             resq 2
pfd:            resq 1
alignb 16
numtab:         resd 256            ; [len, d0, d1, d2] decimal strings
inbuf:          resb INBUF_SIZE
alignb 16
fb:             resd MAX_W*MAX_H
textures:       resd NUM_TEX*TEX_PIX
outbuf:         resb OUTBUF_SIZE

; ----------------------------------------------------------------------------
section .text
; ----------------------------------------------------------------------------

global _start
_start:
    ; save the terminal mode, then switch to raw input
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCGETS
    lea     rdx, [termios_orig]
    syscall
    test    rax, rax
    js      .notty

    lea     rsi, [termios_orig]
    lea     rdi, [termios_raw]
    mov     ecx, 64
    rep     movsb
    ; iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON)
    and     dword [termios_raw+0], ~(0x1|0x2|0x8|0x20|0x40|0x80|0x100|0x400)
    ; lflag &= ~(ISIG|ICANON|ECHO|ECHONL|IEXTEN)
    and     dword [termios_raw+12], ~(0x1|0x2|0x8|0x40|0x8000)
    mov     byte [termios_raw+17+5], 0      ; VTIME, VMIN: never block,
    mov     byte [termios_raw+17+6], 0      ; read_wait polls instead
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [termios_raw]
    syscall

    lea     rsi, [s_init]
    mov     edx, s_init_len
    call    write_all

    ; ASCII map -> cell values
    lea     rsi, [map]
    mov     ecx, MAP_W*MAP_H
.conv:
    sub     byte [rsi], '0'
    inc     rsi
    dec     ecx
    jnz     .conv

    call    gen_numtab
    call    gen_textures
    mov     byte [show_map], 1
    mov     byte [dirty], 1

.main_loop:
    call    update_size
    call    tick
    cmp     byte [pending], 0       ; terminal still drawing the last frame:
    jne     .wait                   ; keep draining input instead of queueing
    cmp     byte [dirty], 0
    je      .wait
    call    render
    call    present
    mov     byte [dirty], 0
    mov     byte [pending], 1
    mov     byte [pend_reads], 0
.wait:
    cmp     byte [pending], 0
    je      .read
    inc     byte [pend_reads]       ; give up on terminals that never answer
    cmp     byte [pend_reads], 10
    jb      .read
    mov     byte [pending], 0
.read:
    call    handle_input
    test    eax, eax
    jz      .main_loop

    ; leave kitty keyboard mode and swallow what's still in flight (key
    ; releases, DA1 replies) so none of it lands in the shell
    lea     rsi, [s_kbd_off]
    mov     edx, s_kbd_off_len
    call    write_all
    movzx   r14d, byte [pending]
    inc     r14d                    ; DA1 replies still to come
    mov     r13d, 20
.drain:
    mov     edx, 100
    call    read_wait
    test    rax, rax
    jz      .restore
    lea     rdi, [inbuf]
    mov     rcx, rax
.scan:
    cmp     byte [rdi], 'c'
    jne     .scan_next
    dec     r14d
    jz      .restore
.scan_next:
    inc     rdi
    dec     rcx
    jnz     .scan
    dec     r13d
    jnz     .drain

    ; restore terminal and leave
.restore:
    mov     eax, SYS_IOCTL
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [termios_orig]
    syscall
    lea     rsi, [s_fini]
    mov     edx, s_fini_len
    call    write_all
    mov     eax, SYS_EXIT
    xor     edi, edi
    syscall

.notty:
    mov     eax, SYS_WRITE
    mov     edi, 2
    lea     rsi, [s_notty]
    mov     edx, s_notty_len
    syscall
    mov     eax, SYS_EXIT
    mov     edi, 1
    syscall

; ----------------------------------------------------------------------------
; write_all: rsi = buffer, rdx = length; writes everything to stdout
; ----------------------------------------------------------------------------
write_all:
    test    rdx, rdx
    jz      .done
.loop:
    mov     eax, SYS_WRITE
    mov     edi, 1
    syscall
    test    rax, rax
    jle     .err
    add     rsi, rax
    sub     rdx, rax
    jnz     .loop
.done:
    ret
.err:
    cmp     rax, -4                 ; EINTR
    je      .loop
    cmp     rax, -11                ; EAGAIN
    je      .loop
    ret

; ----------------------------------------------------------------------------
; update_size: query the terminal and derive the framebuffer size
; ----------------------------------------------------------------------------
update_size:
    mov     eax, SYS_IOCTL
    mov     edi, 1
    mov     esi, TIOCGWINSZ
    lea     rdx, [winsz]
    syscall
    movzx   ecx, word [winsz]       ; rows
    movzx   eax, word [winsz+2]     ; cols
    test    rax, rax
    jns     .ok
    xor     eax, eax
    xor     ecx, ecx
.ok:
    mov     edx, 80
    test    eax, eax
    cmovz   eax, edx
    mov     edx, 24
    test    ecx, ecx
    cmovz   ecx, edx
    mov     edx, MAX_W
    cmp     eax, edx
    cmova   eax, edx
    shl     ecx, 1
    mov     edx, MAX_H
    cmp     ecx, edx
    cmova   ecx, edx
    and     ecx, ~1
    cmp     eax, [scr_w]
    jne     .changed
    cmp     ecx, [scr_h]
    jne     .changed
    ret
.changed:
    mov     [scr_w], eax
    mov     [scr_h], ecx
    mov     byte [dirty], 1
    lea     rsi, [s_clear]
    mov     edx, s_clear_len
    jmp     write_all

; ----------------------------------------------------------------------------
; handle_input: waits for keys and applies them; returns eax = 1 to quit
;
; With the kitty keyboard protocol, press and release events update the held
; key mask and tick moves the player. Otherwise each key (or autorepeat) is
; a fixed step, as before.
; ----------------------------------------------------------------------------
handle_input:
    mov     edx, 100                ; idle: wake for resizes now and then
    cmp     byte [pending], 0
    jne     .wait
    mov     al, [keys]
    or      al, [latch]
    jz      .wait
    mov     edx, 4                  ; keys held: come back for the next tick
.wait:
    call    read_wait
    test    rax, rax
    jnz     .got
    mov     byte [pending], 0       ; quiet for the whole wait: no ack is coming
    jmp     .none
.got:
    mov     r12, rax
    xor     ebx, ebx
.next:
    cmp     rbx, r12
    jae     .none
    movzx   eax, byte [inbuf + rbx]
    inc     rbx
    cmp     al, 27
    je      .esc
    cmp     al, 3                   ; Ctrl-C
    je      .quit
    or      al, 0x20                ; fold to lower case
    cmp     al, 'w'
    je      .fwd
    cmp     al, 's'
    je      .back
    cmp     al, 'a'
    je      .sleft
    cmp     al, 'd'
    je      .sright
    cmp     al, 'j'
    je      .tleft
    cmp     al, 'l'
    je      .tright
    cmp     al, 'm'
    je      .map
    cmp     al, 'q'
    je      .quit
    jmp     .next
.esc:
    call    getc                    ; sequence may arrive split
    jc      .quit                   ; nothing followed: lone Esc
    cmp     al, '['
    je      .csi
    cmp     al, 'O'
    jne     .quit
    call    getc                    ; SS3 arrow keys
    jc      .none
    cmp     al, 'A'
    je      .fwd
    cmp     al, 'B'
    je      .back
    cmp     al, 'C'
    je      .tright
    cmp     al, 'D'
    je      .tleft
    jmp     .next

    ; CSI [priv] p1 [; p2 [: ev]] final
    ;   r8d = number being read (-1: none), r9d = field, r10d = sub-field
    ;   r13d = p1 (key code), r14d = p2 (modifiers + 1), r15d = event type
.csi:
    mov     byte [csi_priv], 0
    mov     r8d, -1
    xor     r9d, r9d
    xor     r10d, r10d
    xor     r13d, r13d
    mov     r14d, 1
    mov     r15d, 1
.csi_byte:
    call    getc
    jc      .none
    cmp     al, '0'
    jb      .csi_sep
    cmp     al, '9'
    ja      .csi_sep
    sub     al, '0'
    movzx   eax, al
    test    r8d, r8d
    jns     .csi_acc
    xor     r8d, r8d
.csi_acc:
    imul    r8d, r8d, 10
    add     r8d, eax
    jmp     .csi_byte
.csi_sep:
    call    csi_commit
    cmp     al, 0x40
    jae     .csi_final
    cmp     al, ';'
    jne     .csi_colon
    inc     r9d
    xor     r10d, r10d
    jmp     .csi_byte
.csi_colon:
    cmp     al, ':'
    jne     .csi_priv
    inc     r10d
    jmp     .csi_byte
.csi_priv:
    cmp     al, '<'                 ; < = > ? introduce private sequences
    jb      .csi_byte
    mov     [csi_priv], al
    jmp     .csi_byte

.csi_final:
    cmp     byte [csi_priv], '?'
    jne     .csi_key
    cmp     al, 'c'
    je      .ack
    cmp     al, 'u'                 ; reply to the keyboard flags query
    jne     .next
    and     r13d, KBD_FLAGS
    cmp     r13d, KBD_FLAGS
    sete    byte [kitty]
    jmp     .next
.ack:
    mov     byte [pending], 0       ; DA1 answer: the frame is on screen
    jmp     .next
.csi_key:
    cmp     byte [csi_priv], 0
    jne     .next
    cmp     al, 'u'
    je      .kcode
    cmp     al, 'O'                 ; focus lost: releases will never come
    jne     .arrow
    mov     byte [keys], 0
    jmp     .next
.arrow:
    mov     ecx, K_FWD
    cmp     al, 'A'
    je      .key
    mov     ecx, K_BACK
    cmp     al, 'B'
    je      .key
    mov     ecx, K_TR
    cmp     al, 'C'
    je      .key
    mov     ecx, K_TL
    cmp     al, 'D'
    je      .key
    jmp     .next
.kcode:
    cmp     r15d, 3                 ; releases only matter for movement
    je      .kmove
    cmp     r13d, 27
    je      .quit
    cmp     r13d, 'q'
    je      .quit
    cmp     r13d, 'c'
    jne     .kmap
    lea     eax, [r14d - 1]
    test    eax, 4                  ; Ctrl
    jnz     .quit
.kmap:
    cmp     r13d, 'm'
    jne     .kmove
    cmp     r15d, 1                 ; not on autorepeat
    je      .map
    jmp     .next
.kmove:
    mov     ecx, K_FWD
    cmp     r13d, 'w'
    je      .key
    mov     ecx, K_BACK
    cmp     r13d, 's'
    je      .key
    mov     ecx, K_SL
    cmp     r13d, 'a'
    je      .key
    mov     ecx, K_SR
    cmp     r13d, 'd'
    je      .key
    mov     ecx, K_TL
    cmp     r13d, 'j'
    je      .key
    mov     ecx, K_TR
    cmp     r13d, 'l'
    je      .key
    jmp     .next

    ; ecx = movement bit, r15d = 1 press / 2 repeat / 3 release
.key:
    cmp     byte [kitty], 0
    je      .impulse
    cmp     r15d, 3
    je      .release
    or      [keys], cl
    cmp     r15d, 1
    jne     .next
    or      [latch], cl             ; a tap shorter than a tick still moves
    jmp     .next
.release:
    not     cl
    and     [keys], cl
    jmp     .next
.impulse:
    cmp     r15d, 3
    je      .next
    test    cl, K_FWD
    jnz     .fwd
    test    cl, K_BACK
    jnz     .back
    test    cl, K_SL
    jnz     .sleft
    test    cl, K_SR
    jnz     .sright
    test    cl, K_TL
    jnz     .tleft
    jmp     .tright

.fwd:
    movsd   xmm0, [dirX]
    mulsd   xmm0, [f_move]
    movsd   xmm1, [dirY]
    mulsd   xmm1, [f_move]
    jmp     .move
.back:
    movsd   xmm0, [dirX]
    mulsd   xmm0, [f_nmove]
    movsd   xmm1, [dirY]
    mulsd   xmm1, [f_nmove]
    jmp     .move
.sright:                            ; right = (-dirY, dirX)
    movsd   xmm0, [dirY]
    mulsd   xmm0, [f_nmove]
    movsd   xmm1, [dirX]
    mulsd   xmm1, [f_move]
    jmp     .move
.sleft:
    movsd   xmm0, [dirY]
    mulsd   xmm0, [f_move]
    movsd   xmm1, [dirX]
    mulsd   xmm1, [f_nmove]
.move:
    call    try_move
    jmp     .moved
.tright:
    movsd   xmm0, [f_rotc]
    movsd   xmm1, [f_rots]
    call    rotate
    jmp     .moved
.tleft:
    movsd   xmm0, [f_rotc]
    movsd   xmm1, [f_nrots]
    call    rotate
    jmp     .moved
.map:
    xor     byte [show_map], 1
.moved:
    mov     byte [dirty], 1
    jmp     .next
.none:
    xor     eax, eax
    ret
.quit:
    mov     eax, 1
    ret

; csi_commit: store the number in r8d into the slot for (r9d, r10d); keeps al
csi_commit:
    test    r8d, r8d
    js      .done
    test    r9d, r9d
    jnz     .f1
    test    r10d, r10d
    jnz     .done
    mov     r13d, r8d
    jmp     .done
.f1:
    cmp     r9d, 1
    jne     .done
    test    r10d, r10d
    jnz     .ev
    mov     r14d, r8d
    jmp     .done
.ev:
    cmp     r10d, 1
    jne     .done
    mov     r15d, r8d
.done:
    mov     r8d, -1
    ret

; getc: next input byte in al (CF clear), waiting <= 100 ms for more;
; CF set if nothing arrived. Uses rbx = index, r12 = count.
getc:
    cmp     rbx, r12
    jb      .have
    mov     edx, 100
    call    read_wait
    xor     ebx, ebx
    mov     r12, rax
    test    rax, rax
    jz      .empty
.have:
    movzx   eax, byte [inbuf + rbx]
    inc     rbx
    clc
    ret
.empty:
    stc
    ret

; read_wait: edx = timeout in ms -> rax = bytes read into inbuf (0 if none)
read_wait:
    mov     dword [pfd], 0          ; fd 0
    mov     dword [pfd+4], 1        ; POLLIN
    mov     eax, SYS_POLL
    lea     rdi, [pfd]
    mov     esi, 1
    syscall
    test    rax, rax
    jle     .zero
    xor     eax, eax                ; SYS_READ
    xor     edi, edi
    lea     rsi, [inbuf]
    mov     edx, INBUF_SIZE
    syscall
    test    rax, rax
    jg      .ret
.zero:
    xor     eax, eax
.ret:
    ret

; ----------------------------------------------------------------------------
; tick: advance held-key movement in fixed steps of TICK_NS
; ----------------------------------------------------------------------------
tick:
    mov     al, [keys]
    or      al, [latch]
    jnz     .active
    mov     byte [ticking], 0
    ret
.active:
    call    now_ns
    cmp     byte [ticking], 0
    jne     .run
    mov     byte [ticking], 1       ; first step right away
    lea     rdx, [rax - TICK_NS]
    mov     [last_tick], rdx
.run:
    mov     r13, rax
    sub     rax, [last_tick]
    xor     edx, edx
    mov     ecx, TICK_NS
    div     rcx
    test    rax, rax
    jz      .done
    imul    rdx, rax, TICK_NS
    add     [last_tick], rdx
    cmp     rax, MAX_TICKS          ; long stall: drop the backlog
    jbe     .steps
    mov     eax, MAX_TICKS
    mov     [last_tick], r13
.steps:
    mov     r14, rax
.step:
    movzx   ebx, byte [keys]
    or      bl, [latch]
    mov     byte [latch], 0
    call    sim_step
    dec     r14
    jnz     .step
    mov     byte [dirty], 1
.done:
    ret

; sim_step: one tick of movement for the key mask in bl
sim_step:
    test    bl, K_FWD
    jz      .back
    movsd   xmm0, [dirX]
    mulsd   xmm0, [f_tmove]
    movsd   xmm1, [dirY]
    mulsd   xmm1, [f_tmove]
    call    try_move
.back:
    test    bl, K_BACK
    jz      .sl
    movsd   xmm0, [dirX]
    mulsd   xmm0, [f_ntmove]
    movsd   xmm1, [dirY]
    mulsd   xmm1, [f_ntmove]
    call    try_move
.sl:
    test    bl, K_SL
    jz      .sr
    movsd   xmm0, [dirY]
    mulsd   xmm0, [f_tmove]
    movsd   xmm1, [dirX]
    mulsd   xmm1, [f_ntmove]
    call    try_move
.sr:
    test    bl, K_SR
    jz      .tl
    movsd   xmm0, [dirY]
    mulsd   xmm0, [f_ntmove]
    movsd   xmm1, [dirX]
    mulsd   xmm1, [f_tmove]
    call    try_move
.tl:
    test    bl, K_TL
    jz      .tr
    movsd   xmm0, [f_trotc]
    movsd   xmm1, [f_ntrots]
    call    rotate
.tr:
    test    bl, K_TR
    jz      .done
    movsd   xmm0, [f_trotc]
    movsd   xmm1, [f_trots]
    call    rotate
.done:
    ret

; now_ns: rax = CLOCK_MONOTONIC in nanoseconds
now_ns:
    mov     eax, SYS_CLOCK_GETTIME
    mov     edi, 1                  ; CLOCK_MONOTONIC
    lea     rsi, [ts]
    syscall
    mov     rax, [ts]
    imul    rax, rax, 1000000000
    add     rax, [ts+8]
    ret

; rotate: xmm0 = cos, xmm1 = sin; rotates the view direction
rotate:
    movsd   xmm2, [dirX]
    movsd   xmm3, [dirY]
    movsd   xmm4, xmm2
    mulsd   xmm4, xmm0
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm1
    subsd   xmm4, xmm5              ; x*c - y*s
    mulsd   xmm2, xmm1
    mulsd   xmm3, xmm0
    addsd   xmm2, xmm3              ; x*s + y*c
    movsd   [dirX], xmm4
    movsd   [dirY], xmm2
    ret

; try_move: xmm0 = dx, xmm1 = dy; moves per axis so walls can be slid along
try_move:
    movapd  xmm2, xmm0
    andpd   xmm2, [sign_mask]
    orpd    xmm2, [f_margin2]       ; copysign(0.2, dx)
    addsd   xmm2, xmm0
    addsd   xmm2, [posX]
    movsd   xmm3, [posY]
    call    is_wall
    test    eax, eax
    jnz     .y
    movsd   xmm2, [posX]
    addsd   xmm2, xmm0
    movsd   [posX], xmm2
.y:
    movapd  xmm3, xmm1
    andpd   xmm3, [sign_mask]
    orpd    xmm3, [f_margin2]
    addsd   xmm3, xmm1
    addsd   xmm3, [posY]
    movsd   xmm2, [posX]
    call    is_wall
    test    eax, eax
    jnz     .done
    movsd   xmm3, [posY]
    addsd   xmm3, xmm1
    movsd   [posY], xmm3
.done:
    ret

; is_wall: xmm2 = x, xmm3 = y -> eax nonzero if solid (or outside the map)
is_wall:
    cvttsd2si eax, xmm2
    cvttsd2si ecx, xmm3
    cmp     eax, MAP_W
    jae     .solid
    cmp     ecx, MAP_H
    jae     .solid
    imul    ecx, ecx, MAP_W
    add     ecx, eax
    movzx   eax, byte [map + rcx]
    ret
.solid:
    mov     eax, 1
    ret

; ----------------------------------------------------------------------------
; render: build one frame into fb
; ----------------------------------------------------------------------------
render:
    ; camera plane perpendicular to dir, sized so pixels stay square
    cvtsi2sd xmm0, dword [scr_w]
    mov     eax, [scr_h]
    add     eax, eax
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    maxsd   xmm0, [f_lmin]
    minsd   xmm0, [f_lmax]
    movsd   xmm1, [dirY]
    mulsd   xmm1, xmm0
    xorpd   xmm1, [sign_mask]
    movsd   [planeX], xmm1          ; planeX = -dirY * L
    movsd   xmm1, [dirX]
    mulsd   xmm1, xmm0
    movsd   [planeY], xmm1          ; planeY =  dirX * L

    call    draw_floor
    call    draw_walls
    cmp     byte [show_map], 0
    je      .done
    call    draw_minimap
.done:
    ret

; calc_shade: xmm0 = distance -> eax = brightness 16..256 (clobbers ecx, xmm0-1)
calc_shade:
    mulsd   xmm0, [f_fogk]
    movsd   xmm1, [f_256]
    subsd   xmm1, xmm0
    cvttsd2si eax, xmm1
    mov     ecx, 16
    cmp     eax, ecx
    cmovl   eax, ecx
    mov     ecx, 256
    cmp     eax, ecx
    cmovg   eax, ecx
    ret

; ----------------------------------------------------------------------------
; draw_floor: textured floor and ceiling, cast one scanline at a time
; ----------------------------------------------------------------------------
draw_floor:
    pxor    xmm14, xmm14
    cvtsi2sd xmm8, dword [scr_w]
    movsd   xmm2, [dirX]
    subsd   xmm2, [planeX]          ; leftmost ray
    movsd   xmm3, [dirY]
    subsd   xmm3, [planeY]
    movsd   xmm4, [planeX]
    addsd   xmm4, xmm4
    divsd   xmm4, xmm8              ; per-column ray delta
    movsd   xmm5, [planeY]
    addsd   xmm5, xmm5
    divsd   xmm5, xmm8
    mov     r12d, [scr_h]
    shr     r12d, 1                 ; y = H/2
.row:
    cmp     r12d, [scr_h]
    jge     .done
    mov     eax, [scr_h]
    shr     eax, 1
    mov     ecx, r12d
    sub     ecx, eax
    cvtsi2sd xmm0, ecx
    addsd   xmm0, [f_half]          ; p = y - H/2 + 0.5
    cvtsi2sd xmm6, dword [scr_h]
    mulsd   xmm6, [f_half]
    divsd   xmm6, xmm0              ; rowDist = (H/2) / p
    movsd   xmm10, xmm4
    mulsd   xmm10, xmm6
    movsd   xmm11, xmm5
    mulsd   xmm11, xmm6
    movsd   xmm12, xmm2
    mulsd   xmm12, xmm6
    addsd   xmm12, [posX]
    movsd   xmm13, xmm3
    mulsd   xmm13, xmm6
    addsd   xmm13, [posY]
    mulsd   xmm10, [f_tex]          ; work in texel units
    mulsd   xmm11, [f_tex]
    mulsd   xmm12, [f_tex]
    mulsd   xmm13, [f_tex]
    movsd   xmm0, xmm6
    call    calc_shade
    movd    xmm15, eax
    pshuflw xmm15, xmm15, 0
    mov     eax, r12d
    imul    eax, [scr_w]
    lea     r14, [fb + rax*4]       ; floor row
    mov     eax, [scr_h]
    sub     eax, r12d
    dec     eax
    imul    eax, [scr_w]
    lea     r15, [fb + rax*4]       ; mirrored ceiling row
    xor     r13d, r13d
.px:
    cvttsd2si eax, xmm12
    cvttsd2si ecx, xmm13
    mov     edx, eax
    sar     edx, 6
    mov     esi, ecx
    sar     esi, 6
    add     edx, esi
    and     edx, 1                  ; checkerboard tile
    and     eax, 63
    and     ecx, 63
    shl     ecx, 6
    add     ecx, eax                ; texel offset
    add     edx, 4
    shl     edx, 12
    add     edx, ecx
    mov     eax, [textures + rdx*4]
    SHADE   eax
    mov     [r14 + r13*4], eax
    mov     eax, [textures + (6*TEX_PIX)*4 + rcx*4]
    SHADE   eax
    mov     [r15 + r13*4], eax
    addsd   xmm12, xmm10
    addsd   xmm13, xmm11
    inc     r13d
    cmp     r13d, [scr_w]
    jl      .px
    inc     r12d
    jmp     .row
.done:
    ret

; ----------------------------------------------------------------------------
; draw_walls: one DDA ray per screen column
; ----------------------------------------------------------------------------
draw_walls:
    pxor    xmm14, xmm14
    cvtsi2sd xmm8, dword [scr_w]
    cvtsi2sd xmm9, dword [scr_h]
    xor     r12d, r12d              ; column
.col:
    cmp     r12d, [scr_w]
    jge     .done
    cvtsi2sd xmm0, r12d
    addsd   xmm0, xmm0
    divsd   xmm0, xmm8
    subsd   xmm0, [f_one]           ; cameraX in [-1, 1)
    movsd   xmm1, [planeX]
    mulsd   xmm1, xmm0
    addsd   xmm1, [dirX]            ; rayDirX
    movsd   xmm2, [planeY]
    mulsd   xmm2, xmm0
    addsd   xmm2, [dirY]            ; rayDirY
    cvttsd2si r8d, [posX]           ; mapX
    cvttsd2si r9d, [posY]           ; mapY
    movsd   xmm3, [f_one]
    divsd   xmm3, xmm1
    andpd   xmm3, [abs_mask]        ; deltaDistX (inf if rayDirX == 0)
    movsd   xmm4, [f_one]
    divsd   xmm4, xmm2
    andpd   xmm4, [abs_mask]        ; deltaDistY
    xorpd   xmm7, xmm7

    comisd  xmm1, xmm7
    jae     .xpos
    mov     r10d, -1
    cvtsi2sd xmm0, r8d
    movsd   xmm5, [posX]
    subsd   xmm5, xmm0
    mulsd   xmm5, xmm3
    jmp     .xdone
.xpos:
    mov     r10d, 1
    lea     eax, [r8 + 1]
    cvtsi2sd xmm5, eax
    subsd   xmm5, [posX]
    mulsd   xmm5, xmm3
.xdone:
    comisd  xmm2, xmm7
    jae     .ypos
    mov     r11d, -1
    cvtsi2sd xmm0, r9d
    movsd   xmm6, [posY]
    subsd   xmm6, xmm0
    mulsd   xmm6, xmm4
    jmp     .dda
.ypos:
    mov     r11d, 1
    lea     eax, [r9 + 1]
    cvtsi2sd xmm6, eax
    subsd   xmm6, [posY]
    mulsd   xmm6, xmm4

.dda:
    comisd  xmm5, xmm6
    jae     .stepy
    addsd   xmm5, xmm3
    add     r8d, r10d
    xor     ebx, ebx                ; side 0: hit an x-facing wall
    jmp     .check
.stepy:
    addsd   xmm6, xmm4
    add     r9d, r11d
    mov     ebx, 1
.check:
    cmp     r8d, MAP_W
    jae     .oob
    cmp     r9d, MAP_H
    jae     .oob
    imul    eax, r9d, MAP_W
    add     eax, r8d
    movzx   eax, byte [map + rax]
    test    eax, eax
    jz      .dda
    jmp     .hit
.oob:
    mov     eax, 1
.hit:
    lea     r13d, [rax - 1]         ; texture index

    ; perpendicular distance (avoids fisheye)
    test    ebx, ebx
    jnz     .perpy
    subsd   xmm5, xmm3
    movsd   xmm10, xmm5
    jmp     .perp
.perpy:
    subsd   xmm6, xmm4
    movsd   xmm10, xmm6
.perp:
    maxsd   xmm10, [f_eps]

    movsd   xmm0, xmm9
    divsd   xmm0, xmm10
    cvttsd2si r14d, xmm0            ; lineHeight
    mov     eax, 1
    cmp     r14d, eax
    cmovl   r14d, eax
    mov     eax, [scr_h]
    shr     eax, 1
    mov     ecx, r14d
    shr     ecx, 1
    mov     r15d, eax
    sub     r15d, ecx               ; drawStart
    mov     ebp, r15d               ; unclamped start
    mov     esi, eax
    add     esi, ecx                ; drawEnd (exclusive)
    xor     edx, edx
    test    r15d, r15d
    cmovl   r15d, edx
    mov     edx, [scr_h]
    cmp     esi, edx
    cmovg   esi, edx

    ; where along the wall the ray hit
    movsd   xmm0, xmm10
    test    ebx, ebx
    jnz     .wx1
    mulsd   xmm0, xmm2
    addsd   xmm0, [posY]
    jmp     .wx
.wx1:
    mulsd   xmm0, xmm1
    addsd   xmm0, [posX]
.wx:
    cvttsd2si eax, xmm0
    cvtsi2sd xmm7, eax
    subsd   xmm0, xmm7
    mulsd   xmm0, [f_tex]
    cvttsd2si r8d, xmm0
    and     r8d, 63                 ; texX
    xorpd   xmm7, xmm7
    test    ebx, ebx
    jnz     .fl1
    comisd  xmm1, xmm7
    jbe     .nofl
    jmp     .flip
.fl1:
    comisd  xmm2, xmm7
    jae     .nofl
.flip:
    xor     r8d, 63
.nofl:

    ; 16.16 fixed-point texture step down the column
    mov     eax, TEX_SIZE << 16
    xor     edx, edx
    div     r14d
    mov     r9d, eax
    mov     eax, r15d
    sub     eax, ebp
    imul    eax, r9d
    mov     r10d, eax               ; texPos

    movsd   xmm0, xmm10
    call    calc_shade
    test    ebx, ebx
    jz      .noside
    imul    eax, eax, 3             ; y-facing walls a bit darker
    shr     eax, 2
.noside:
    movd    xmm15, eax
    pshuflw xmm15, xmm15, 0

    mov     r11d, r13d
    shl     r11d, 12
    add     r11d, r8d
    lea     rdi, [textures + r11*4] ; texture column
    mov     eax, r15d
    imul    eax, [scr_w]
    add     eax, r12d
    lea     rdx, [fb + rax*4]
    mov     ecx, [scr_w]
    shl     ecx, 2                  ; row stride
    sub     esi, r15d
    jle     .next
.pix:
    mov     eax, r10d
    shr     eax, 16
    and     eax, 63
    shl     eax, 6
    mov     eax, [rdi + rax*4]
    SHADE   eax
    mov     [rdx], eax
    add     rdx, rcx
    add     r10d, r9d
    dec     esi
    jnz     .pix
.next:
    inc     r12d
    jmp     .col
.done:
    ret

; ----------------------------------------------------------------------------
; draw_minimap: overlay in the top-left corner
; ----------------------------------------------------------------------------
draw_minimap:
    mov     eax, [scr_h]
    xor     edx, edx
    mov     ecx, 90
    div     ecx
    inc     eax
    mov     ecx, 3
    cmp     eax, ecx
    cmova   eax, ecx
    mov     ebp, eax                ; pixels per cell
    imul    eax, MAP_W
    add     eax, 2
    cmp     eax, [scr_w]
    jg      .done
    cmp     eax, [scr_h]
    jg      .done
    pxor    xmm14, xmm14
    mov     eax, 100
    movd    xmm15, eax
    pshuflw xmm15, xmm15, 0
    xor     r12d, r12d              ; map y
.my:
    xor     r13d, r13d              ; map x
.mx:
    imul    eax, r12d, MAP_W
    add     eax, r13d
    movzx   ebx, byte [map + rax]
    xor     r14d, r14d
.j:
    xor     r15d, r15d
.i:
    mov     eax, r12d
    imul    eax, ebp
    add     eax, r14d
    inc     eax
    imul    eax, [scr_w]
    mov     ecx, r13d
    imul    ecx, ebp
    add     ecx, r15d
    inc     ecx
    add     eax, ecx
    lea     rdi, [fb + rax*4]
    test    ebx, ebx
    jz      .empty
    mov     eax, [map_colors + rbx*4]
    jmp     .put
.empty:
    mov     eax, [rdi]              ; darken what's underneath
    SHADE   eax
.put:
    mov     [rdi], eax
    inc     r15d
    cmp     r15d, ebp
    jl      .i
    inc     r14d
    cmp     r14d, ebp
    jl      .j
    inc     r13d
    cmp     r13d, MAP_W
    jl      .mx
    inc     r12d
    cmp     r12d, MAP_H
    jl      .my

    movsd   xmm0, [dirX]
    addsd   xmm0, [posX]
    movsd   xmm1, [dirY]
    addsd   xmm1, [posY]
    mov     eax, 0xFF8040
    call    map_dot
    movsd   xmm0, [posX]
    movsd   xmm1, [posY]
    mov     eax, 0xFFFF40
    call    map_dot
.done:
    ret

; map_dot: xmm0/xmm1 = world position, eax = colour, ebp = cell size
map_dot:
    cvtsi2sd xmm2, ebp
    mulsd   xmm0, xmm2
    mulsd   xmm1, xmm2
    cvttsd2si ecx, xmm0
    cvttsd2si edx, xmm1
    inc     ecx
    inc     edx
    imul    edx, [scr_w]
    add     edx, ecx
    mov     [fb + rdx*4], eax
    ret

; ----------------------------------------------------------------------------
; present: encode fb as half-block glyphs with truecolour escapes
; ----------------------------------------------------------------------------
present:
    lea     rsi, [s_fpre]
    lea     rdi, [outbuf]
    mov     ecx, s_fpre_len
    rep     movsb
    mov     r8d, -1                 ; last foreground
    mov     r9d, -1                 ; last background
    mov     r12d, [scr_w]
    mov     r13d, [scr_h]
    shr     r13d, 1                 ; text rows
    mov     r15, r12
    shl     r15, 2                  ; bytes per pixel row
    lea     rsi, [fb]
    xor     r14d, r14d
.row:
    lea     r10, [rsi + r15]        ; bottom pixel row
    xor     ebx, ebx
.cell:
    mov     eax, [rsi + rbx*4]      ; top pixel -> fg
    cmp     eax, r8d
    je      .bg
    mov     r8d, eax
    mov     edx, 0x38335B1B         ; ESC [ 3 8
    call    emit_color
.bg:
    mov     eax, [r10 + rbx*4]  ; bottom pixel -> bg
    cmp     eax, r9d
    je      .glyph
    mov     r9d, eax
    mov     edx, 0x38345B1B         ; ESC [ 4 8
    call    emit_color
.glyph:
    mov     dword [rdi], 0x008096E2 ; U+2580 upper half block
    add     rdi, 3
    inc     ebx
    cmp     ebx, r12d
    jl      .cell
    lea     rsi, [rsi + r15*2]
    inc     r14d
    cmp     r14d, r13d
    jge     .flush
    mov     word [rdi], 0x0A0D
    add     rdi, 2
    jmp     .row
.flush:
    lea     rsi, [s_fpost]
    mov     ecx, s_fpost_len
    rep     movsb
    lea     rsi, [outbuf]
    mov     rdx, rdi
    sub     rdx, rsi
    jmp     write_all

; emit_color: rdi = out, eax = 0x00RRGGBB, edx = first 4 bytes of the prefix
; writes "<prefix>;2;R;G;Bm"; clobbers ecx, edx
emit_color:
    mov     [rdi], edx
    mov     dword [rdi+3], 0x3B323B38 ; "8;2;"
    add     rdi, 7
    mov     ecx, eax
    shr     ecx, 16
    and     ecx, 0xFF
    call    emit_u8
    mov     byte [rdi], ';'
    inc     rdi
    movzx   ecx, ah
    call    emit_u8
    mov     byte [rdi], ';'
    inc     rdi
    movzx   ecx, al
    call    emit_u8
    mov     byte [rdi], 'm'
    inc     rdi
    ret

; emit_u8: ecx = 0..255, appended as decimal at rdi; clobbers ecx, edx
emit_u8:
    mov     edx, [numtab + rcx*4]
    movzx   ecx, dl
    shr     edx, 8
    mov     [rdi], edx
    add     rdi, rcx
    ret

; ----------------------------------------------------------------------------
; gen_numtab: decimal strings for 0..255
; ----------------------------------------------------------------------------
gen_numtab:
    xor     ecx, ecx
    mov     ebx, 10
.loop:
    mov     eax, ecx
    cmp     ecx, 10
    jb      .one
    cmp     ecx, 100
    jb      .two
    xor     edx, edx
    mov     esi, 100
    div     esi
    add     al, '0'
    mov     [numtab + rcx*4 + 1], al
    mov     eax, edx
    xor     edx, edx
    div     ebx
    add     al, '0'
    mov     [numtab + rcx*4 + 2], al
    add     dl, '0'
    mov     [numtab + rcx*4 + 3], dl
    mov     byte [numtab + rcx*4], 3
    jmp     .next
.two:
    xor     edx, edx
    div     ebx
    add     al, '0'
    mov     [numtab + rcx*4 + 1], al
    add     dl, '0'
    mov     [numtab + rcx*4 + 2], dl
    mov     byte [numtab + rcx*4], 2
    jmp     .next
.one:
    add     al, '0'
    mov     [numtab + rcx*4 + 1], al
    mov     byte [numtab + rcx*4], 1
.next:
    inc     ecx
    cmp     ecx, 256
    jb      .loop
    ret

; ----------------------------------------------------------------------------
; gen_textures: procedural 64x64 textures
; each generator gets x = r14d, y = r13d, noise = r11d (0..31) and leaves
; r, g, b in eax, ecx, edx before jumping to tex_store
; ----------------------------------------------------------------------------
gen_textures:
    lea     rdi, [textures]
    xor     r12d, r12d
.t:
    xor     r13d, r13d
.y:
    xor     r14d, r14d
.x:
    call    rnd
    jmp     [tex_jt + r12*8]
tex_store:
    call    pack_rgb
    stosd
    inc     r14d
    cmp     r14d, TEX_SIZE
    jl      gen_textures.x
    inc     r13d
    cmp     r13d, TEX_SIZE
    jl      gen_textures.y
    inc     r12d
    cmp     r12d, NUM_TEX
    jl      gen_textures.t
    ret

; red brick, offset every other course
tg_brick:
    mov     ecx, r13d
    and     ecx, 15
    jz      .mortar
    mov     eax, r13d
    and     eax, 16
    add     eax, r14d
    mov     r8d, eax
    and     eax, 31
    jz      .mortar
    shr     r8d, 5
    and     r8d, 1
    mov     r9d, r13d
    shr     r9d, 4
    lea     r9d, [r9*2 + r8]
    imul    r9d, r9d, 53
    and     r9d, 31                 ; per-brick tint
    lea     eax, [r11 + r9 + 0x80]
    mov     ecx, r11d
    shr     ecx, 1
    add     ecx, 0x30
    mov     edx, r11d
    shr     edx, 1
    add     edx, 0x22
    mov     r8d, r13d               ; bottom edge of each course a bit darker
    and     r8d, 15
    cmp     r8d, 15
    jne     tex_store
    sub     eax, 0x28
    sub     ecx, 0x10
    sub     edx, 0x0C
    jmp     tex_store
.mortar:
    lea     eax, [r11 + 0x78]
    mov     ecx, eax
    lea     edx, [rax - 8]
    jmp     tex_store

; bevelled blue-grey stone blocks
tg_stone:
    mov     r8d, r14d
    and     r8d, 31
    mov     r9d, r13d
    and     r9d, 15
    mov     eax, r11d
    shr     eax, 1
    add     eax, 0x60
    test    r8d, r8d
    jz      .light
    test    r9d, r9d
    jz      .light
    cmp     r8d, 31
    je      .dark
    cmp     r9d, 15
    je      .dark
    jmp     .out
.light:
    add     eax, 0x30
    jmp     .out
.dark:
    sub     eax, 0x30
.out:
    mov     ecx, eax
    lea     edx, [rax + 0x18]
    sub     eax, 8
    jmp     tex_store

; vertical wooden planks with grain
tg_wood:
    mov     r8d, r14d
    and     r8d, 15                 ; x within plank
    mov     r9d, r14d
    shr     r9d, 4                  ; plank number
    mov     r10d, r11d
    shr     r10d, 2
    lea     eax, [r10 + 0x8C]
    lea     ecx, [r10 + 0x5C]
    mov     edx, 0x34
    test    r8d, r8d
    jz      .gap
    imul    r10d, r9d, 23
    and     r10d, 63
    cmp     r10d, r13d              ; plank joint
    je      .gap
    imul    r10d, r9d, 17
    add     r10d, r13d
    lea     r10d, [r10 + r8*2]
    and     r10d, 7
    cmp     r10d, 2
    jae     tex_store
    sub     eax, 0x14               ; grain stripe
    sub     ecx, 0x0E
    sub     edx, 0x08
    jmp     tex_store
.gap:
    mov     eax, 0x40
    mov     ecx, 0x28
    mov     edx, 0x14
    jmp     tex_store

; mossy green tiles
tg_moss:
    mov     r8d, r14d
    and     r8d, 15
    mov     r9d, r13d
    and     r9d, 15
    test    r8d, r8d
    jz      .grout
    test    r9d, r9d
    jz      .grout
    mov     eax, r11d
    shr     eax, 1
    add     eax, 0x28
    lea     ecx, [r11 + 0x70]
    mov     edx, r11d
    shr     edx, 1
    add     edx, 0x38
    cmp     r11d, 28
    jb      tex_store
    add     ecx, 0x30               ; bright moss specks
    add     eax, 0x10
    jmp     tex_store
.grout:
    mov     eax, r11d
    shr     eax, 2
    add     eax, 0x30
    lea     ecx, [rax + 8]
    mov     edx, eax
    jmp     tex_store

; floor tile, light grey
tg_floor_a:
    mov     eax, r11d
    shr     eax, 1
    add     eax, 0x6A
    call    tile_edge
    mov     ecx, eax
    sub     ecx, 4
    mov     edx, eax
    sub     edx, 10
    jmp     tex_store

; floor tile, dark slate
tg_floor_b:
    mov     eax, r11d
    shr     eax, 1
    add     eax, 0x50
    call    tile_edge
    lea     edx, [rax + 4]
    sub     eax, 6
    mov     ecx, eax
    jmp     tex_store

; tile_edge: eax = value; darkens it on the tile border
tile_edge:
    test    r14d, r14d
    jz      .edge
    test    r13d, r13d
    jz      .edge
    cmp     r14d, 63
    je      .soft
    cmp     r13d, 63
    je      .soft
    ret
.edge:
    mov     eax, 0x38
    ret
.soft:
    sub     eax, 0x18
    ret

; ceiling, dark boards with beams
tg_ceil:
    mov     eax, r11d
    shr     eax, 2
    add     eax, 0x48
    mov     r8d, r14d
    and     r8d, 31
    cmp     r8d, 3
    jae     .board
    sub     eax, 0x18
.board:
    mov     ecx, eax
    lea     edx, [rax - 10]
    add     eax, 8
    jmp     tex_store

; pack_rgb: eax, ecx, edx = r, g, b (clamped) -> eax = 0x00RRGGBB
pack_rgb:
    xor     r8d, r8d
    mov     r9d, 255
    cmp     eax, r8d
    cmovl   eax, r8d
    cmp     eax, r9d
    cmovg   eax, r9d
    cmp     ecx, r8d
    cmovl   ecx, r8d
    cmp     ecx, r9d
    cmovg   ecx, r9d
    cmp     edx, r8d
    cmovl   edx, r8d
    cmp     edx, r9d
    cmovg   edx, r9d
    shl     eax, 16
    shl     ecx, 8
    or      eax, ecx
    or      eax, edx
    ret

; rnd: xorshift32 -> r11d = 0..31; clobbers eax, edx
rnd:
    mov     eax, [rng]
    mov     edx, eax
    shl     edx, 13
    xor     eax, edx
    mov     edx, eax
    shr     edx, 17
    xor     eax, edx
    mov     edx, eax
    shl     edx, 5
    xor     eax, edx
    mov     [rng], eax
    mov     r11d, eax
    shr     r11d, 7
    and     r11d, 31
    ret
