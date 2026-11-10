// PhoneControlShared.h — shared between the Minis app and the MinisBroadcast extension.
// Port 8310 and a distinct FRAME_KEY so Minis never clashes with MiniPaw (8300)
// if both are installed on the same phone.
#ifndef PhoneControlShared_h
#define PhoneControlShared_h

#ifndef PC_PORT
#define PC_PORT 8310
#endif
#define PC_FRAME_KEY "minis-frame-9d41c7e2"

#endif
