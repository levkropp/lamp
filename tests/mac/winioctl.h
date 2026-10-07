/* APFS creates sparse holes on ftruncate; no Windows sparse-file ioctl exists. */
#ifndef LAMP_MAC_TEST_WINIOCTL_H
#define LAMP_MAC_TEST_WINIOCTL_H
#define FSCTL_SET_SPARSE 0
static int DeviceIoControl(HANDLE h, unsigned code, void *in, unsigned in_size,
                          void *out, unsigned out_size, DWORD *returned, void *overlap) {
    (void)h; (void)code; (void)in; (void)in_size; (void)out; (void)out_size; (void)overlap;
    *returned=0; return 1;
}
#endif
