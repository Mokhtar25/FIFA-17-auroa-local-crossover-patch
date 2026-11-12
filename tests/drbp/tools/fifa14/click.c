/* click.exe <x> <y> — move the Wine cursor and click there for real.
 *
 * The 3DM launcher's window is transparent and ignores macOS synthetic
 * clicks, so the click has to come in through Wine's input stack.  Bring the
 * window to the front with System Events first (run.sh does), then click the
 * "Launch Game" button. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    POINT old;
    INPUT in[2];
    int x, y;

    if (argc < 3) { printf("usage: %s <x> <y>\n", argv[0]); return 2; }
    x = atoi(argv[1]); y = atoi(argv[2]);
    GetCursorPos(&old);
    SetCursorPos(x, y);
    Sleep(120);
    memset(in, 0, sizeof in);
    in[0].type = INPUT_MOUSE; in[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    in[1].type = INPUT_MOUSE; in[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(2, in, sizeof(INPUT));
    Sleep(120);
    SetCursorPos(old.x, old.y);
    printf("clicked %d,%d (was %ld,%ld)\n", x, y, (long)old.x, (long)old.y);
    return 0;
}
