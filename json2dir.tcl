#!/usr/bin/env tclsh
# json2dir: create the directory tree a JSON document describes, in the current directory.
# Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
# Core Tcl 8.6 only: hand-written UTF-8 check and JSON parser.

# All strings are kept as raw UTF-8 bytes (one Tcl char per byte). With the system encoding
# set to iso8859-1, Tcl passes those bytes to the file system unchanged.
encoding system iso8859-1

proc fail {msg} { return -code error -errorcode JSON2DIR $msg }

# --- §3: strict UTF-8 ------------------------------------------------------------------
proc checkUtf8 {s} {
    set n [string length $s]
    set i 0
    while {$i < $n} {
        scan [string index $s $i] %c b
        if {$b < 0x80} { incr i; continue }
        if {$b >= 0xC2 && $b <= 0xDF} { set k 1; set lo 0x80; set hi 0xBF
        } elseif {$b == 0xE0} { set k 2; set lo 0xA0; set hi 0xBF
        } elseif {$b == 0xED} { set k 2; set lo 0x80; set hi 0x9F
        } elseif {$b >= 0xE1 && $b <= 0xEF} { set k 2; set lo 0x80; set hi 0xBF
        } elseif {$b == 0xF0} { set k 3; set lo 0x90; set hi 0xBF
        } elseif {$b >= 0xF1 && $b <= 0xF3} { set k 3; set lo 0x80; set hi 0xBF
        } elseif {$b == 0xF4} { set k 3; set lo 0x80; set hi 0x8F
        } else { fail "input is not valid UTF-8" }
        for {set j 1} {$j <= $k} {incr j} {
            if {$i + $j >= $n} { fail "input is not valid UTF-8" }
            scan [string index $s [expr {$i + $j}]] %c c
            if {$c < $lo || $c > $hi} { fail "input is not valid UTF-8" }
            set lo 0x80; set hi 0xBF
        }
        incr i [expr {$k + 1}]
    }
}

# --- §3: strict JSON -------------------------------------------------------------------
# Values: {str BYTES} {arr LIST} {obj DICT} {other KIND}
proc skipWs {} {
    upvar #0 S s P p
    while {[string first [string index $s $p] " \t\n\r"] >= 0 && [string index $s $p] ne ""} { incr p }
}

proc utf8 {cp} {
    if {$cp < 0x80} { return [format %c $cp] }
    if {$cp < 0x800} { return [format %c%c [expr {0xC0 | ($cp >> 6)}] [expr {0x80 | ($cp & 0x3F)}]] }
    if {$cp < 0x10000} {
        return [format %c%c%c [expr {0xE0 | ($cp >> 12)}] [expr {0x80 | (($cp >> 6) & 0x3F)}] \
            [expr {0x80 | ($cp & 0x3F)}]]
    }
    return [format %c%c%c%c [expr {0xF0 | ($cp >> 18)}] [expr {0x80 | (($cp >> 12) & 0x3F)}] \
        [expr {0x80 | (($cp >> 6) & 0x3F)}] [expr {0x80 | ($cp & 0x3F)}]]
}

proc hex4 {} {
    upvar #0 S s P p
    set h [string range $s $p [expr {$p + 3}]]
    if {![regexp {^[0-9A-Fa-f]{4}$} $h]} { fail "invalid \\u escape at byte $p" }
    incr p 4
    return [expr {"0x$h"}]
}

proc parseString {} {
    upvar #0 S s P p
    incr p ;# opening quote
    set out ""
    while 1 {
        set c [string index $s $p]
        if {$c eq ""} { fail "unterminated string" }
        if {$c eq "\""} { incr p; return $out }
        scan $c %c b
        if {$b < 0x20} { fail "control character in string at byte $p" }
        if {$c ne "\\"} { append out $c; incr p; continue }
        incr p
        set e [string index $s $p]
        incr p
        switch -- $e {
            \" { append out \" }
            \\ { append out \\ }
            / { append out / }
            b { append out \b }
            f { append out \f }
            n { append out \n }
            r { append out \r }
            t { append out \t }
            u {
                set cp [hex4]
                if {$cp >= 0xD800 && $cp <= 0xDBFF} {
                    if {[string range $s $p [expr {$p + 1}]] ne "\\u"} { fail "unpaired surrogate in string" }
                    incr p 2
                    set lo [hex4]
                    if {$lo < 0xDC00 || $lo > 0xDFFF} { fail "unpaired surrogate in string" }
                    set cp [expr {0x10000 + (($cp - 0xD800) << 10) + ($lo - 0xDC00)}]
                } elseif {$cp >= 0xDC00 && $cp <= 0xDFFF} {
                    fail "unpaired surrogate in string"
                }
                append out [utf8 $cp]
            }
            default { fail "invalid escape at byte $p" }
        }
    }
}

proc parseValue {} {
    upvar #0 S s P p
    skipWs
    set c [string index $s $p]
    switch -- $c {
        \{ {
            incr p
            set d [dict create]
            skipWs
            if {[string index $s $p] eq "\}"} { incr p; return [list obj $d] }
            while 1 {
                skipWs
                if {[string index $s $p] ne "\""} { fail "expected a member name at byte $p" }
                set k [parseString]
                skipWs
                if {[string index $s $p] ne ":"} { fail "expected ':' at byte $p" }
                incr p
                dict set d $k [parseValue]   ;# duplicate names: the last one wins (§4.2)
                skipWs
                set c [string index $s $p]
                incr p
                if {$c eq "\}"} { return [list obj $d] }
                if {$c ne ","} { fail "expected ',' or '\}' at byte [expr {$p - 1}]" }
            }
        }
        \[ {
            incr p
            set l {}
            skipWs
            if {[string index $s $p] eq "\]"} { incr p; return [list arr $l] }
            while 1 {
                lappend l [parseValue]
                skipWs
                set c [string index $s $p]
                incr p
                if {$c eq "\]"} { return [list arr $l] }
                if {$c ne ","} { fail "expected ',' or '\]' at byte [expr {$p - 1}]" }
            }
        }
        \" { return [list str [parseString]] }
    }
    foreach lit {true false null} {
        if {[string range $s $p [expr {$p + [string length $lit] - 1}]] eq $lit} {
            incr p [string length $lit]
            return [list other $lit]
        }
    }
    if {[regexp -start $p {\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?} $s m]} {
        incr p [string length $m]
        return [list other number]
    }
    fail "unexpected input at byte $p"
}

proc parseDocument {bytes} {
    global S P
    checkUtf8 $bytes
    if {[string range $bytes 0 2] eq "\xEF\xBB\xBF"} { set bytes [string range $bytes 3 end] }
    set S $bytes
    set P 0
    set v [parseValue]
    skipWs
    if {$P != [string length $S]} { fail "trailing data at byte $P" }
    return $v
}

# --- §4, §6: validate the whole document before touching the file system ------------------
proc validate {v where} {
    lassign $v kind x
    switch -- $kind {
        str { return }
        arr {
            if {[llength $x] != 2 || [lindex $x 0 0] ne "str" || [lindex $x 1 0] ne "str"} {
                fail "$where: an array must be \[\"link\", target\] or \[\"script\", content\]"
            }
            set k [lindex $x 0 1]
            if {$k ne "link" && $k ne "script"} { fail "$where: unknown array kind \"$k\"" }
            if {$k eq "link" && [string first \0 [lindex $x 1 1]] >= 0} { fail "$where: a link target cannot contain NUL" }
        }
        obj {
            dict for {name child} $x {
                set path [expr {$where eq "." ? $name : "$where/$name"}]
                if {$name in {"" . ..} || [string first / $name] >= 0 || [string first \0 $name] >= 0} {
                    fail "$path: invalid name"
                }
                validate $child $path
            }
        }
        default { fail "$where: $x values are not allowed" }
    }
}

# --- §5: apply -------------------------------------------------------------------------
# Paths are always "./name" so Tcl never applies ~ expansion. The tree is applied with
# cd into each directory, so relative link targets are checked from the link's directory.
proc entryType {p} {
    if {[catch {file lstat $p st}]} { return "" }
    return $st(type)
}

proc clear {p t} {
    if {$t eq ""} return
    if {$t eq "directory"} { fail "$p: a directory is in the way" }
    file delete -- $p
}

proc writeFile {p content executable} {
    set f [open $p {WRONLY CREAT EXCL} 0666]
    fconfigure $f -translation binary
    puts -nonewline $f $content
    close $f
    if {$executable} {
        set mode [scan [file attributes $p -permissions] %o]
        file attributes $p -permissions [format %04o [expr {$mode | 0o111}]]
    }
}

# Tcl's [file link] refuses to create a link whose target does not exist. For a target that
# is a plain name in the current directory, an empty placeholder file is created for the
# moment of the call and removed right after. Other dangling targets are a known gap.
proc makeLink {p name target} {
    set placeholder ""
    if {[entryType $p] eq "" && ![file exists ./$target] && [string first / $target] < 0
            && $target ni {"" . ..} && $target ne $name} {
        if {[entryType ./$target] eq ""} {
            close [open ./$target {WRONLY CREAT EXCL}]
            set placeholder ./$target
        }
    }
    set rc [catch {file link -symbolic $p $target} err]
    if {$placeholder ne ""} { file delete -- $placeholder }
    if {$rc} { fail "$p: cannot create symlink to \"$target\": $err" }
}

proc apply {tree} {
    foreach name [lsort [dict keys $tree]] {
        set p ./$name
        lassign [dict get $tree $name] kind x
        set t [entryType $p]
        switch -- $kind {
            str { clear $p $t; writeFile $p $x 0 }
            arr {
                clear $p $t
                lassign [lindex $x 0] - k
                lassign [lindex $x 1] - c
                if {$k eq "script"} {
                    writeFile $p $c 1
                } else {
                    makeLink $p $name $c
                }
            }
            obj {
                if {$t ne "directory"} {
                    if {$t ne ""} { file delete -- $p }
                    file mkdir $p
                }
                cd $p
                apply $x
                cd ..
            }
        }
    }
}

proc main {argv} {
    if {[llength $argv] > 0} {
        puts stderr "usage: json2dir < document.json"
        return 2
    }
    if {[catch {
        fconfigure stdin -translation binary
        set doc [parseDocument [read stdin]]
        if {[lindex $doc 0] ne "obj"} { fail "the root of the document must be an object" }
        validate $doc .
        apply [lindex $doc 1]
    } err]} {
        puts stderr "json2dir: $err"
        return 1
    }
    return 0
}

exit [main $argv]
