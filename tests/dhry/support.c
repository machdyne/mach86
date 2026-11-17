/*
 * Mach86: what Dhrystone 2.1 needs from a C library, for a bare
 * real-mode machine. Dhrystone itself is fetched, not kept here
 * (tools/dhry.sh).
 *
 * Nothing is printed and no time is taken: the benchmark is measured
 * by counting instructions and cycles from outside. RUNS is set on
 * the compiler command line.
 */
static char heap[256];
static unsigned heap_used;

char *malloc(unsigned n)
{
    char *p = heap + heap_used;
    heap_used += (n + 3) & ~3u;
    return p;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != 0)
        ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

int printf(const char *f, ...) { (void)f; return 0; }
int scanf(const char *f, int *n) { (void)f; *n = RUNS; return 1; }
long time(long *t) { (void)t; return 0; }

/* Referenced by the report at the end, which is never reached because
 * the measured time is zero. */
float __floatsisf(int x) { (void)x; return 0; }
float __mulsf3(float a, float b) { (void)a; (void)b; return 0; }
float __divsf3(float a, float b) { (void)a; (void)b; return 0; }
double __extendsfdf2(float x) { (void)x; return 0; }
double __muldf3(double a, double b) { (void)a; (void)b; return 0; }
double __divdf3(double a, double b) { (void)a; (void)b; return 0; }
float __truncdfsf2(double x) { (void)x; return 0; }
