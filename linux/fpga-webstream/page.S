/* Embed index.html into the binary (index_html .. index_html_end). */
	.section .rodata
	.global index_html, index_html_end
	.balign 4
index_html:
	.incbin "index.html"
index_html_end:
	.byte 0
	.section .note.GNU-stack,"",%progbits
