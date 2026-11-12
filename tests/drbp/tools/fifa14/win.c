/* win.exe — list top-level windows: handle, pid, visible, rect, class, title.
 *
 * The FIFA 14 launcher's window is titled "SOG" and has a transparent
 * background, so it is invisible in a screenshot; and the game's splash is
 * class "fifa14.exe SPLASH".  This says whether either exists and where. */
#include <windows.h>
#include <stdio.h>

static BOOL CALLBACK cb(HWND h, LPARAM l)
{
    char cls[128] = "", title[160] = "";
    RECT r;
    DWORD pid = 0;

    (void)l;
    GetClassNameA(h, cls, sizeof cls - 1);
    GetWindowTextA(h, title, sizeof title - 1);
    GetWindowRect(h, &r);
    GetWindowThreadProcessId(h, &pid);
    printf("%08lx pid=%lu vis=%d rect=%ld,%ld %ldx%ld class=%s title=%s\n",
           (unsigned long)(ULONG_PTR)h, (unsigned long)pid, IsWindowVisible(h) ? 1 : 0,
           (long)r.left, (long)r.top, (long)(r.right - r.left), (long)(r.bottom - r.top),
           cls, title);
    return TRUE;
}

int main(void)
{
    EnumWindows(cb, 0);
    return 0;
}
