# json2dir-tcl

json2dir in core Tcl 8.6: reads a JSON document on stdin and creates the directory tree it describes in the current directory.

    tclsh json2dir.tcl < document.json

Known gap: Tcl's `file link` refuses dangling targets; only targets that are a plain sibling name are handled (via a short-lived placeholder file).
