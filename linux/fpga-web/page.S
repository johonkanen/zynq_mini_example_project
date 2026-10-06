/* Embed the web page and its assets into the binary (<name> .. <name>_end). */
	.section .rodata
	.macro asset name, file
	.global \name, \name\()_end
	.balign 4
\name:
	.incbin "\file"
\name\()_end:
	.byte 0
	.endm

	asset index_html,   "index.html"
	asset uplot_js,     "vendor/uPlot.iife.min.js"
	asset uplot_css,    "vendor/uPlot.min.css"
	.section .note.GNU-stack,"",%progbits
