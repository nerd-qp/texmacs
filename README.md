# GNU TeXmacs (Chez port)
This is an attempt to make texmacs run on chez scheme. I tested the compile_kernel.scm script in MacOS, and so far most .scm files compile. The TeXmacs program runs but with some existing bugs to iron out.

Still needs a lot of work to achieve the following:
1. The program works;
2. Changes to existing Guile code should be minimal (though some are necessary heavy modification).
3. Need to figure out the automated build tools.
4. The project attempt is aided by LLM. I try to review most code and ideas before them. In a final pass, I will try to sit through the entire modifications again.
5. In the coming days, I will continue working on this: perhaps reverting a lot of the changes and squashing some commits. So not intended for public collaboration yet!

# Some design points
Chez Scheme is built on the R6RS, and Guile-1.8's standard differs quite significantly. Some code from Guile-1.8 is not meant to be run on Chez Scheme. Most notably the module systems between the two are the main source of pain for this port. On a high level, this chez-port uses the module system of its own, with no notion of inheritance. Some hacking was done to make it work.

And the other main issue is the dynamic nature of Guile implementation, whereas, Chez Scheme compilers expect more static definitions. During compilation, within each module Chez compiler demands you put all definitions before any expression can occur. We hack this by rearranging the scheme forms and outputting a new R6RS compilable .scm file by reading the original code. Another problem is that the Guile-port's macro uses internal definitions, which Chez hates when you compile them inside module. Chez enforces two phases of compilation: first phase, it will try to expand all macros (without evaluating the .scm file), and so if you use local functions within said macro, the compiler will not see them (unless you explicitly tell Chez it's for macro-only; in which case, you can't use the same function during run-time). In second phase, Chez will then compile all forms into a .so file.
