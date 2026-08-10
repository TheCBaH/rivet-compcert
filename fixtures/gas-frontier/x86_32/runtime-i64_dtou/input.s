 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_dtou; .align 16; __compcert_i64_dtou:
        subl $4, %esp
        fldl 8(%esp)
        flds LC1
        fucomp
        fnstsw %ax
        sahf
        jbe 1f
        fnstcw 0(%esp)
        movw 0(%esp), %ax
        movb $12, %ah
        movw %ax, 2(%esp)
        fldcw 2(%esp)
        fistpll 8(%esp)
        movl 8(%esp), %eax
        movl 12(%esp), %edx
        fldcw 0(%esp)
        addl $4, %esp
        ret
1: fsubs LC1
        fnstcw 0(%esp)
        movw 0(%esp), %ax
        movb $12, %ah
        movw %ax, 2(%esp)
        fldcw 2(%esp)
        fistpll 8(%esp)
        movl 8(%esp), %eax
        movl 12(%esp), %edx
        addl $0x80000000, %edx
        fldcw 0(%esp)
        addl $4, %esp
        ret
        .p2align 2
LC1: .long 0x5f000000
.type __compcert_i64_dtou, @function; .size __compcert_i64_dtou, . - __compcert_i64_dtou
