#ifndef ZTE_LAUNCHER_VPN_VIEW_H
#define ZTE_LAUNCHER_VPN_VIEW_H

/* Keep every LVGL coordinate inside its signed 16-bit range, even when a
 * catalog contains 1024 profiles. Normal lists use one continuous viewport. */
enum {
 VPN_VIEWPORT_Y=80, VPN_VIEWPORT_HEIGHT=342, VPN_STATUS_HINT_HEIGHT=22,
 VPN_LIST_ROWS=128, VPN_PROFILE_HEIGHT=60, VPN_PROFILE_STEP=68,
 VPN_LIST_MORE_HEIGHT=40, VPN_LIST_MORE_STEP=48, VPN_PROFILE_EVENT_BASE=1000
};
struct vpn_list_window { int first,count,total; };
static inline struct vpn_list_window vpn_list_window(int total,int first){
 if(total<0)total=0;
 if(first<0||first>=total)first=0;
 first=first/VPN_LIST_ROWS*VPN_LIST_ROWS;
 int count=total-first;if(count>VPN_LIST_ROWS)count=VPN_LIST_ROWS;
 return (struct vpn_list_window){first,count,total};
}
static inline int vpn_list_row_y(struct vpn_list_window window,int row){
 return (window.first?VPN_LIST_MORE_STEP:0)+row*VPN_PROFILE_STEP;
}
static inline int vpn_list_has_more(struct vpn_list_window window){
 return window.first+window.count<window.total;
}
static inline int vpn_list_height(struct vpn_list_window window){
 if(!window.count)return 0;
 return vpn_list_row_y(window,window.count-1)+VPN_PROFILE_HEIGHT+
  (vpn_list_has_more(window)?VPN_PROFILE_STEP-VPN_PROFILE_HEIGHT+VPN_LIST_MORE_HEIGHT:0);
}
#endif
