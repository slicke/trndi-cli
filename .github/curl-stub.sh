#!/bin/sh
# Builds a stand-in libcurl.so for the Linux release builds to link against.
#
# Debian and Ubuntu version libcurl's symbols (CURL_OPENSSL_4); Fedora, Arch
# and most others do not. A binary linked against the Debian library records
# that version as a requirement, and everywhere else the loader then prints
# "libcurl.so.4: no version information available" on every start. Linked
# against a libcurl with no versions the binary asks for none, which runs
# quietly on both kinds: on Debian the plain names bind to the versioned
# symbols all the same.
#
# The stand-in is a link name and nothing more. Its soname is libcurl.so.4,
# so at run time the loader fetches the system's real library. Labels with no
# code under them assemble the same for every CPU, and as and ld are there
# already, being what fpc itself links with.
#
# The symbols are the ones trndi.curl imports. A new import there fails the
# link with an undefined reference until it is added here.
#
# FPC searches the system library directories ahead of any -Fl one, so the
# stand-in only counts where no libcurl.so link name is installed: leave
# libcurl4-openssl-dev out.
set -eu

dir=${1:?usage: curl-stub.sh <dir>}
mkdir -p "$dir"

{
  echo '.text'
  for sym in curl_global_init curl_easy_init curl_easy_setopt \
             curl_easy_perform curl_easy_getinfo curl_easy_strerror \
             curl_easy_cleanup curl_slist_append curl_slist_free_all; do
    printf '.globl %s\n.type %s, %%function\n%s:\n' "$sym" "$sym" "$sym"
  done
  echo '.section .note.GNU-stack,"",%progbits'
} > "$dir/curl-stub.s"

as -o "$dir/curl-stub.o" "$dir/curl-stub.s"
ld -shared -soname libcurl.so.4 -o "$dir/libcurl.so" "$dir/curl-stub.o"
