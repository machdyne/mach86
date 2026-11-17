/*
 * Mach86 reference model -- an SD card in SPI mode.
 *
 * Sources: SD-PHY (SPI mode: command frames, R1/R3/R7 responses, data
 * tokens, CSD version 2.0).
 *
 * Models a high-capacity (block-addressed) card backed by an image
 * file. Enough of the protocol for a BIOS: reset, voltage check,
 * initialisation, OCR, CSD, single-block read and write.
 */
#include <string.h>
#include "pc.h"

static void respond(pc_sd *sd, const uint8_t *bytes, int n)
{
    /* One idle byte before the response, as real cards give at least. */
    sd->resp[0] = 0xFF;
    memcpy(sd->resp + 1, bytes, (size_t)n);
    sd->resp_len = n + 1;
    sd->resp_pos = 0;
}

static void r1(pc_sd *sd, uint8_t v)
{
    respond(sd, &v, 1);
}

static void command(pc_sd *sd)
{
    int cmd = sd->cmd[0] & 0x3F;
    uint32_t arg = ((uint32_t)sd->cmd[1] << 24) | ((uint32_t)sd->cmd[2] << 16)
                 | ((uint32_t)sd->cmd[3] << 8) | sd->cmd[4];
    uint8_t idle = sd->idle ? 0x01 : 0x00;
    uint8_t buf[600];
    int acmd = sd->acmd;
    sd->acmd = 0;

    if (acmd && cmd == 41) {            /* SD_SEND_OP_COND */
        if (++sd->acmd41_calls >= 2)
            sd->idle = 0;
        r1(sd, sd->idle ? 0x01 : 0x00);
        return;
    }
    switch (cmd) {
    case 0:                             /* GO_IDLE_STATE */
        sd->idle = 1;
        sd->acmd41_calls = 0;
        sd->writing = 0;
        r1(sd, 0x01);
        break;
    case 8:                             /* SEND_IF_COND */
        buf[0] = idle;
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0x01;
        buf[4] = (uint8_t)arg;          /* echo the check pattern */
        respond(sd, buf, 5);
        break;
    case 55:                            /* APP_CMD */
        sd->acmd = 1;
        r1(sd, idle);
        break;
    case 58:                            /* READ_OCR: powered up, CCS set */
        buf[0] = idle;
        buf[1] = sd->idle ? 0x00 : 0xC0;
        buf[2] = 0xFF;
        buf[3] = 0x80;
        buf[4] = 0x00;
        respond(sd, buf, 5);
        break;
    case 9: {                           /* SEND_CSD, version 2.0 */
        uint32_t c_size = (sd->sectors + 1023) / 1024;
        c_size = c_size ? c_size - 1 : 0;
        memset(buf, 0, sizeof buf);
        buf[0] = 0x00;                  /* R1 */
        buf[1] = 0xFF;
        buf[2] = 0xFE;                  /* data token */
        buf[3] = 0x40;                  /* CSD_STRUCTURE = 1 */
        buf[3 + 5] = 0x59;              /* READ_BL_LEN = 9 */
        buf[3 + 7] = (uint8_t)((c_size >> 16) & 0x3F);
        buf[3 + 8] = (uint8_t)(c_size >> 8);
        buf[3 + 9] = (uint8_t)c_size;
        buf[3 + 15] = 0x01;
        buf[19] = buf[20] = 0xFF;       /* CRC, not checked in SPI mode */
        respond(sd, buf, 21);
        break;
    }
    case 16:                            /* SET_BLOCKLEN: fixed at 512 */
    case 13:                            /* SEND_STATUS (first byte) */
        r1(sd, idle);
        break;
    case 17:                            /* READ_SINGLE_BLOCK */
        if (sd->idle || !sd->image || arg >= sd->sectors) {
            r1(sd, sd->idle ? 0x05 : 0x40);     /* illegal / parameter */
            break;
        }
        memset(buf, 0, sizeof buf);
        buf[0] = 0x00;
        buf[1] = 0xFF;
        buf[2] = 0xFE;
        fseek(sd->image, (long)arg * 512, SEEK_SET);
        if (fread(buf + 3, 1, 512, sd->image) != 512) {
            /* Short image: the rest of the sector reads as zeros. */
        }
        buf[515] = buf[516] = 0xFF;
        respond(sd, buf, 517);
        break;
    case 24:                            /* WRITE_BLOCK */
        if (sd->idle || !sd->image || arg >= sd->sectors) {
            r1(sd, sd->idle ? 0x05 : 0x40);
            break;
        }
        sd->wr_lba = arg;
        sd->writing = 1;
        r1(sd, 0x00);
        break;
    default:
        r1(sd, (uint8_t)(idle | 0x04)); /* illegal command */
        break;
    }
}

void sd_deselect(pc_sd *sd)
{
    sd->cmd_len = 0;
    sd->resp_len = sd->resp_pos = 0;
    if (sd->writing == 1)
        sd->writing = 0;
}

uint8_t sd_exchange(pc_sd *sd, uint8_t mosi)
{
    /* A response in progress goes out whatever the host sends. */
    if (sd->resp_pos < sd->resp_len)
        return sd->resp[sd->resp_pos++];

    if (sd->writing == 1) {             /* waiting for the data token */
        if (mosi == 0xFE) {
            sd->writing = 2;
            sd->wr_len = 0;
        }
        return 0xFF;
    }
    if (sd->writing == 2) {             /* 512 bytes of data and two of CRC */
        sd->wr_buf[sd->wr_len++] = mosi;
        if (sd->wr_len == 514) {
            static const uint8_t done[] = { 0x05, 0x00, 0x00 };
            fseek(sd->image, (long)sd->wr_lba * 512, SEEK_SET);
            fwrite(sd->wr_buf, 1, 512, sd->image);
            fflush(sd->image);
            sd->writing = 0;
            /* Data accepted, then busy for a moment. */
            memcpy(sd->resp, done, sizeof done);
            sd->resp_len = (int)sizeof done;
            sd->resp_pos = 0;
        }
        return 0xFF;
    }

    if (sd->cmd_len == 0 && (mosi & 0xC0) != 0x40)
        return 0xFF;                    /* not the start of a command */
    sd->cmd[sd->cmd_len++] = mosi;
    if (sd->cmd_len == 6) {
        sd->cmd_len = 0;
        command(sd);
    }
    return 0xFF;
}
