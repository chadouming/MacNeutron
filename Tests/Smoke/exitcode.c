/* Prints its arguments and exits with their count, so the smoke test can tell that
   arguments with spaces reached the game as single arguments. */
#include <stdio.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) printf("arg %d: [%s]\n", i, argv[i]);
    return argc - 1;
}
