#use "topfind";;
#require "js-build-tools.oasis2opam_install";;

open Oasis2opam_install;;

generate ~package:"async_shell"
  [ oasis_lib "async_shell"
  ; file "META" ~section:"lib"
  ]
