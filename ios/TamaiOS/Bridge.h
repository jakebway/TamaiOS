#ifndef TAMAIOS_BRIDGE_H
#define TAMAIOS_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct Emu Emu;

typedef struct {
    uint64_t hash;
    int32_t known;
    uint8_t name[64];
    uint8_t stem[96];
} TgRomInfo;

void tg_free(uint8_t *p, size_t n);
int32_t tg_check_rom(const uint8_t *p, size_t n, TgRomInfo *info);
int32_t tg_rom_from_zip(const uint8_t *p, size_t n, uint8_t **out, size_t *out_len);
int32_t tg_check_snapshot(const uint8_t *rom, size_t rom_len, const uint8_t *snap, size_t snap_len);
double tg_rtc_seconds(int64_t y, uint32_t mo, uint32_t d, uint32_t h, uint32_t mi, uint32_t s);

Emu *tg_create(const uint8_t *rom, size_t rom_len,
               const uint8_t *snap, size_t snap_len,
               const uint8_t *flash, size_t flash_len,
               const char *meta, double rtc_now, double *elapsed);
void tg_destroy(Emu *e);

int32_t tg_tick(Emu *e, double real_dt);
uint32_t tg_take_flags(Emu *e);
void tg_press(Emu *e, int32_t key, double wall);
void tg_release(Emu *e, int32_t key);
void tg_release_all(Emu *e);
int32_t tg_frame(Emu *e, uint32_t *out);
int32_t tg_is_asleep(Emu *e);
size_t tg_take_audio(Emu *e, int16_t *out, size_t max);
void tg_set_volume(Emu *e, double v);
void tg_set_never_sleep(Emu *e, int32_t on);

int32_t tg_snapshot(Emu *e, uint8_t **out, size_t *out_len);
int32_t tg_flash_save(Emu *e, const char *path);
int32_t tg_force_sleep(Emu *e);
void tg_wake(Emu *e);
int32_t tg_advance_clock(Emu *e, double secs);
int32_t tg_sync_clock(Emu *e, double rtc_seconds);
void tg_restart(Emu *e);

void tg_status(Emu *e, uint8_t **out, size_t *out_len);
void tg_log(Emu *e, uint8_t **out, size_t *out_len);
int32_t tg_set_param(Emu *e, const char *name, double v);
int32_t tg_peek(Emu *e, uint32_t addr, uint8_t *out, size_t n);
int32_t tg_profile_sprite(Emu *e, int32_t rom, uint32_t *out);
int32_t tg_profile_look(Emu *e, int32_t *out);
int32_t tg_call_chain(Emu *e, uint32_t *out, size_t max);
int32_t tg_poke(Emu *e, uint32_t addr, const uint8_t *data, size_t n);
void tg_script_press(Emu *e, int32_t key, double delay);
void tg_read_cstr(Emu *e, uint32_t addr, uint8_t **out, size_t *out_len);
void tg_set_wall_clock(Emu *e, double rtc_now);
void tg_set_egg_hold(int on);

/* Bluetooth module: the built-in phone app talks through these */
void tg_radio_enable(Emu *e, int32_t on);
void tg_radio_connect(Emu *e, int32_t on);
int32_t tg_radio_ready(Emu *e);
int32_t tg_radio_write(Emu *e, const uint8_t *d, size_t n);
int32_t tg_radio_read(Emu *e, uint8_t **out, size_t *out_len);
void tg_radio_trace(Emu *e, uint8_t **out, size_t *out_len);

/* Tama Town: marriage */
double tg_clock_drift(Emu *e);
void tg_ir_link(Emu *e, int32_t on);
size_t tg_ir_take(Emu *e, uint8_t *out, size_t max);
void tg_ir_deliver(Emu *e, const uint8_t *data, size_t n);
int32_t tg_mm_load_zip(const uint8_t *p, size_t n);
size_t tg_mm_ids(uint16_t *out, size_t max);
int32_t tg_mm_compose(uint16_t b, int32_t bp, uint16_t m, uint16_t a, int32_t ap, uint16_t k, int32_t kp, uint32_t *out);
int32_t tg_mm_layer(int32_t part, uint16_t id, int32_t pal, uint32_t *out);
int32_t tg_mm_body_info(uint16_t id, int32_t *out);
int32_t tg_mm_wallpaper_count(void);
int32_t tg_mm_wallpaper(int32_t n, int32_t *wh, uint32_t *out);
int32_t tg_mm_palette(int32_t pal, uint32_t *out);
void tg_mm_packet(uint8_t op, uint8_t cmd, uint8_t **out, size_t *out_len);
int32_t tg_mm_visit_info(const uint8_t *p, size_t n);
void tg_mm_visit_name(const uint8_t *p, size_t n, uint8_t **out, size_t *out_len);
int32_t tg_mm_marriage(const uint8_t *visit, size_t visit_len,
                       uint16_t b, int32_t bp, uint16_t m, uint16_t a, int32_t ap, uint16_t k, int32_t kp,
                       uint8_t baby_sex, uint8_t lang, uint8_t kind, const char *name, uint64_t seed,
                       uint8_t **out, size_t *out_len);

void tg_mm_items(uint8_t **out, size_t *out_len);
int32_t tg_mm_item_packet(size_t i, uint32_t points, uint8_t **out, size_t *out_len);
int32_t tg_mm_user_item(const uint8_t *p, size_t n, uint32_t points, uint8_t **out, size_t *out_len);
void tg_mm_user_item_name(const uint8_t *p, size_t n, uint8_t **out, size_t *out_len);
void tg_mm_points_packet(uint32_t points, uint8_t **out, size_t *out_len);
void tg_mm_back_packet(const uint8_t *p, size_t n, uint32_t points, uint8_t **out, size_t *out_len);
void tg_mm_tama_name(const uint8_t *p, size_t n, uint8_t **out, size_t *out_len);

int32_t tg_profile_points(Emu *e);
int32_t tg_profile_adjust_points(Emu *e, int32_t delta);
int32_t tg_profile_attention(Emu *e);


typedef struct NameProbeSeed NameProbeSeed;
typedef struct NameProbe NameProbe;
NameProbeSeed *tg_name_seed_capture(Emu *e);
void tg_name_seed_destroy(NameProbeSeed *p);
void tg_name_seed_text(const NameProbeSeed *p, int32_t kind, uint8_t **out, size_t *n);
NameProbe *tg_name_probe_from_seed(const NameProbeSeed *p);
void tg_name_probe_destroy(NameProbe *p);
int32_t tg_name_probe_step(NameProbe *p, double seconds);
void tg_name_probe_press(NameProbe *p, int32_t key);
int32_t tg_name_probe_rgb(NameProbe *p, uint8_t *out, size_t n);
int32_t tg_name_identity_matches(Emu *e, int32_t stage, uint32_t character, uint32_t signature);
int32_t tg_mm_custom_item(const char *kind, const char *name, uint16_t price, const uint32_t *px, size_t w, size_t h, uint64_t seed, uint32_t points, uint8_t **out, size_t *out_len);

#endif