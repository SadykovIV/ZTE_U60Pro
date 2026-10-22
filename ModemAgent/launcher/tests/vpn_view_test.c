/* Pure viewport geometry; synthetic catalogs only, no modem or profile files. */
#include "../vpn-view.h"
#include "../backend.h"
#include <assert.h>
#include <stdio.h>

int main(void){
 unsigned catalogs=0,profiles=0;
 assert(VPN_VIEWPORT_Y==80&&VPN_VIEWPORT_Y+VPN_VIEWPORT_HEIGHT==422);
 assert(4*VPN_PROFILE_STEP+VPN_PROFILE_HEIGHT<=VPN_VIEWPORT_HEIGHT); /* Five complete rows. */
 assert(VPN_PROFILE_EVENT_BASE>82); /* No overlap with native SIM/control events. */
 for(int total=0;total<=MAX_PROFILES;total++){
  int seen=0;
  do{
   struct vpn_list_window window=vpn_list_window(total,seen);
   assert(window.first==seen&&window.total==total);
   assert(window.count>=0&&window.count<=VPN_LIST_ROWS);
   assert(window.first+window.count<=total);
   int height=vpn_list_height(window);
   assert(height>=0&&height+VPN_VIEWPORT_Y<32767);
   for(int hint=0;hint<=1;hint++){
   int viewport=VPN_VIEWPORT_HEIGHT-hint*VPN_STATUS_HINT_HEIGHT;
   int travel=height>viewport?height-viewport:0;
   for(int row=0;row<window.count;row++){
    int y=vpn_list_row_y(window,row),bottom=y+VPN_PROFILE_HEIGHT;
    assert(y>=0&&bottom<=height);
    if(row)assert(y>=vpn_list_row_y(window,row-1)+VPN_PROFILE_HEIGHT);
    /* Every row can be brought fully inside the scroll viewport. */
    int scroll=y>travel?travel:y;
    assert(y-scroll>=0&&bottom-scroll<=viewport);
    profiles++;
   }
   }
   if(window.first)assert(vpn_list_row_y(window,0)>=VPN_LIST_MORE_HEIGHT);
   if(vpn_list_has_more(window))assert(vpn_list_row_y(window,window.count)+VPN_LIST_MORE_HEIGHT==height);
   else if(window.count)assert(vpn_list_row_y(window,window.count-1)+VPN_PROFILE_HEIGHT==height);
   seen+=window.count;
   if(!vpn_list_has_more(window))break;
  }while(seen<total);
  assert(seen==total);catalogs++;
 }
 struct vpn_list_window empty=vpn_list_window(-1,5);
 assert(!empty.first&&!empty.count&&!empty.total&&!vpn_list_height(empty));
 assert(vpn_list_window(10,-1).first==0&&vpn_list_window(10,11).first==0);
 assert(vpn_list_window(MAX_PROFILES,VPN_LIST_ROWS+3).first==VPN_LIST_ROWS);
 printf("VPN viewport: %u catalogs, %u reachable profile rows; fixed controls and bounded coordinates\n",catalogs,profiles);
 return 0;
}
