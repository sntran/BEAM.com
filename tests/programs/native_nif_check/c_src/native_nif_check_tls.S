/*
 * The TLS models of Rust for native_nif_check_tls.c, which cosmocc
 * does not make for C code: on x86_64 the general dynamic and the local
 * dynamic models (__tls_get_addr), on aarch64 the TLS descriptors. Each
 * function gives the int at its variable, and adds 1 to it.
 */
#if defined(__x86_64__)
#define TLS_DATA .section .tdata,"awT",@progbits
#define TLS_BSS .section .tbss,"awT",@nobits
#else
#define TLS_DATA .section .tdata,"awT",%progbits
#define TLS_BSS .section .tbss,"awT",%nobits
#endif

        TLS_DATA
        .balign 8
        .globl nc_t_dyn
nc_t_dyn:  .long 41
nc_t_local:
        .long 42
        .globl nc_t_ie
nc_t_ie:   .long 43
        .long 0
        TLS_BSS
        .balign 16
nc_t_big:  .zero 256

        .text
#if defined(__x86_64__)
/* General dynamic: the exact sequence of the ABI. */
        .globl nc_t_gd
nc_t_gd:   pushq %rbp
        .byte 0x66
        leaq nc_t_dyn@tlsgd(%rip), %rdi
        .word 0x6666
        rex64
        call __tls_get_addr@PLT
        movl (%rax), %ecx
        leal 1(%rcx), %edx
        movl %edx, (%rax)
        movl %ecx, %eax
        popq %rbp
        ret

/* Local dynamic: the module, then the offset of nc_t_local in it. */
        .globl nc_t_ld
nc_t_ld:   pushq %rbp
        leaq nc_t_local@tlsld(%rip), %rdi
        call __tls_get_addr@PLT
        leaq nc_t_local@dtpoff(%rax), %rax
        movl (%rax), %ecx
        leal 1(%rcx), %edx
        movl %edx, (%rax)
        movl %ecx, %eax
        popq %rbp
        ret

/* The end of nc_t_big, with the local dynamic model and a 64-bit offset. */
        .globl nc_t_big_end
nc_t_big_end:
        pushq %rbp
        leaq nc_t_big@tlsld(%rip), %rdi
        call __tls_get_addr@PLT
        movabsq $nc_t_big@dtpoff+252, %rcx
        movl (%rax,%rcx), %eax
        popq %rbp
        ret
#else
/* A TLS descriptor, as LLVM makes it for Rust: x0 from the descriptor,
 * plus tpidr_el0. */
        .globl nc_t_gd
nc_t_gd:   stp x29, x30, [sp, #-16]!
        mov x29, sp
        adrp x0, :tlsdesc:nc_t_dyn
        ldr x1, [x0, #:tlsdesc_lo12:nc_t_dyn]
        add x0, x0, #:tlsdesc_lo12:nc_t_dyn
        .tlsdesccall nc_t_dyn
        blr x1
        mrs x8, tpidr_el0
        add x0, x8, x0
        ldr w1, [x0]
        add w2, w1, #1
        str w2, [x0]
        mov w0, w1
        ldp x29, x30, [sp], #16
        ret

/* A TLS descriptor of a local variable with an offset. */
        .globl nc_t_ld
nc_t_ld:   stp x29, x30, [sp, #-16]!
        mov x29, sp
        adrp x0, :tlsdesc:nc_t_local
        ldr x1, [x0, #:tlsdesc_lo12:nc_t_local]
        add x0, x0, #:tlsdesc_lo12:nc_t_local
        .tlsdesccall nc_t_local
        blr x1
        mrs x8, tpidr_el0
        add x0, x8, x0
        ldr w1, [x0]
        add w2, w1, #1
        str w2, [x0]
        mov w0, w1
        ldp x29, x30, [sp], #16
        ret

        .globl nc_t_big_end
nc_t_big_end:
        stp x29, x30, [sp, #-16]!
        mov x29, sp
        adrp x0, :tlsdesc:nc_t_big+252
        ldr x1, [x0, #:tlsdesc_lo12:nc_t_big+252]
        add x0, x0, #:tlsdesc_lo12:nc_t_big+252
        .tlsdesccall nc_t_big+252
        blr x1
        mrs x8, tpidr_el0
        ldr w0, [x8, x0]
        ldp x29, x30, [sp], #16
        ret
#endif

        .section .note.GNU-stack,"",%progbits
