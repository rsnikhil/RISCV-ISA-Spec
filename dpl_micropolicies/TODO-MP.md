TODAY

replace Shrinking stuff with updated version

figure out why rdTagSet needs the symbol table -- get some kind of tagset
  printing working

figure out if the "no applicable rule" failure is what we should expect

delete policy-* when finished using them for reference

___

Falling off the end of memory is not a very interesting behavior -- generate it less often or maybe explicitly look for it and halt execution

Try to write an explicit test that exercises the second mutant

there are too mamy magic constants saying how many instructions to generate / execute!

are we generating too many "interesting" immediate fields?

___________________________________________________________
BEFORE JANUARY PI MEETING

replace haskell policy by policy interpreter
(Andrew)

copy over all the mutants from the Coq version
(BCP)

get the heap safety policy running using the interpreter
(All)

________________________
AFTER PI MEETING

start thinking about stack safety!
  - look at the policy in the draper repo

improve mutation testing (BCP / Leo)
  - run cpp separately so that we don't recompile everything every time

haskell-mode for emacs!  (on BCP's work laptop)
