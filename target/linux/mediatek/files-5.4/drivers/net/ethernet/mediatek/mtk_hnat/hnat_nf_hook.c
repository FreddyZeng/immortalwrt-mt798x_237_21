/*   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation; version 2 of the License
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   Copyright (C) 2014-2016 Sean Wang <sean.wang@mediatek.com>
 *   Copyright (C) 2016-2017 John Crispin <blogic@openwrt.org>
 */

#include <linux/netfilter_bridge.h>
#include <linux/netfilter_ipv6.h>

#include <linux/of.h>
#include <net/arp.h>
#include <net/neighbour.h>
#include <net/netfilter/nf_conntrack_helper.h>
#include <net/netfilter/nf_flow_table.h>
#include <net/ipv6.h>
#include <net/ip6_route.h>
#include <net/ip.h>
#include <net/tcp.h>
#include <net/udp.h>
#include <net/netfilter/nf_conntrack.h>
#include <net/netfilter/nf_conntrack_acct.h>
#include <net/netfilter/nf_conntrack_core.h>



#include "nf_hnat_mtk.h"
#include "hnat.h"

#include "../mtk_eth_soc.h"
#include "../mtk_eth_reset.h"

#define do_ge2ext_fast(dev, skb)                                               \
	((IS_LAN(dev) || IS_WAN(dev) || IS_PPD(dev)) && \
	 skb_hnat_is_hashed(skb) && \
	 skb_hnat_reason(skb) == HIT_BIND_FORCE_TO_CPU)
#define do_ext2ge_fast_learn(dev, skb)                                         \
	(IS_PPD(dev) &&                                                        \
	 (skb_hnat_sport(skb) == NR_PDMA_PORT ||                           \
	  skb_hnat_sport(skb) == NR_QDMA_PORT) &&                       \
	  ((get_dev_from_index(skb->vlan_tci & VLAN_VID_MASK)) ||   \
		 get_wandev_from_index(skb->vlan_tci & VLAN_VID_MASK)))

#define do_mape_w2l_fast(dev, skb)                                          \
		(mape_toggle && IS_WAN(dev) && (!is_from_mape(skb)))

static struct ipv6hdr mape_l2w_v6h;
static struct ipv6hdr mape_w2l_v6h;
static inline uint8_t get_wifi_hook_if_index_from_dev(const struct net_device *dev)
{
	int i;

	for (i = 1; i < MAX_IF_NUM; i++) {
		if (hnat_priv->wifi_hook_if[i] == dev)
			return i;
	}

	return 0;
}

static inline int get_ext_device_number(void)
{
	int i, number = 0;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++)
		number += 1;
	return number;
}

static inline int find_extif_from_devname(const char *name)
{
	int i;
	struct extdev_entry *ext_entry;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++) {
		ext_entry = hnat_priv->ext_if[i];
		if (!strcmp(name, ext_entry->name))
			return 1;
	}
	return 0;
}

static inline int get_index_from_dev(const struct net_device *dev)
{
	int i;
	struct extdev_entry *ext_entry;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++) {
		ext_entry = hnat_priv->ext_if[i];
		if (dev == ext_entry->dev)
			return ext_entry->dev->ifindex;
	}
	return 0;
}

static inline struct net_device *get_dev_from_index(int index)
{
	int i;
	struct extdev_entry *ext_entry;
	struct net_device *dev = 0;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++) {
		ext_entry = hnat_priv->ext_if[i];
		if (ext_entry->dev && index == ext_entry->dev->ifindex) {
			dev = ext_entry->dev;
			break;
		}
	}
	return dev;
}

static inline struct net_device *get_wandev_from_index(int index)
{
	if (!hnat_priv->g_wandev)
		hnat_priv->g_wandev = dev_get_by_name(&init_net, hnat_priv->wan);

	if (hnat_priv->g_wandev && hnat_priv->g_wandev->ifindex == index)
		return hnat_priv->g_wandev;
	return NULL;
}

static inline int extif_match(const char *name)
{
	int i;
	struct extdev_entry *ext_entry;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++) {
		ext_entry = hnat_priv->ext_if[i];
		if (!strcmp(name, ext_entry->name) && !ext_entry->dev) {
			return i;
		}
	}

	return -1;
}

static inline bool extif_prefix_match(const char *name)
{
	int i;

	for (i = 0; i < MAX_EXT_PREFIX_NUM && hnat_priv->ext_if_prefix[i]; i++)
	{
		if (strlen(hnat_priv->ext_if_prefix[i]) && 
			!strncmp(name, hnat_priv->ext_if_prefix[i],
				strlen(hnat_priv->ext_if_prefix[i])))
			return true;
	}

	return false;
}

static inline int extif_set_dev(struct net_device *dev, int try_prefix)
{
	struct extdev_entry *ext_entry;
	int extif_index, number;

	extif_index = extif_match(dev->name);

	if (extif_index < 0) {
		/* try extif prefix match */
		if (try_prefix && extif_prefix_match(dev->name)) {
			number = get_ext_device_number();
			if (number >= MAX_EXT_DEVS) {
				pr_info("%s : extdev array is full. %s is not registered\n",
					__func__, dev->name);
				return -1;
			}

			ext_entry = kzalloc(sizeof(*ext_entry), GFP_KERNEL);
			if (!ext_entry)
				return -1;

			strncpy(ext_entry->name, dev->name, IFNAMSIZ - 1);
			dev_hold(dev);
			ext_entry->dev = dev;
			ext_if_add(ext_entry);

			pr_info("%s prefix match (%s)\n", __func__, dev->name);
			return dev->ifindex;
		}
	} else {
		dev_hold(dev);
		hnat_priv->ext_if[extif_index]->dev = dev;
		pr_info("%s(%s)\n", __func__, dev->name);
		return dev->ifindex;
	}

	return -1;
}

static inline int extif_put_dev(struct net_device *dev)
{
	int i;
	struct extdev_entry *ext_entry;

	for (i = 0; i < MAX_EXT_DEVS && hnat_priv->ext_if[i]; i++) {
		ext_entry = hnat_priv->ext_if[i];
		if (ext_entry->dev == dev) {
			ext_entry->dev = NULL;
			dev_put(dev);
			pr_info("%s(%s)\n", __func__, dev->name);

			return 0;
		}
	}

	return -1;
}

int ext_if_add(struct extdev_entry *ext_entry)
{
	int len = get_ext_device_number();

	if (len < MAX_EXT_DEVS)
		hnat_priv->ext_if[len++] = ext_entry;

	return len;
}

int ext_if_del(struct extdev_entry *ext_entry)
{
	int i, j;

	for (i = 0; i < MAX_EXT_DEVS; i++) {
		if (hnat_priv->ext_if[i] == ext_entry) {
			for (j = i; hnat_priv->ext_if[j] && j < MAX_EXT_DEVS - 1; j++)
				hnat_priv->ext_if[j] = hnat_priv->ext_if[j + 1];
			hnat_priv->ext_if[j] = NULL;
			break;
		}
	}

	return i;
}


static void foe_clear_ethdev_bind_entries(struct net_device *dev)
{
	struct net_device *master_dev = dev;
	const struct dsa_port *dp;
	struct foe_entry *entry;
	struct mtk_mac *mac;
	bool match_dev = false;
	int port_id, gmac;
	u32 i, hash_index;
	u32 dsa_tag;
	u32 total = 0;
	/* Get the master device if the device is slave device */
	port_id = hnat_dsa_get_port(&master_dev);
	mac = netdev_priv(master_dev);
	gmac = (mac->id == 1) ? NR_GMAC2_PORT : NR_GMAC1_PORT;
	if (gmac < 0)
		return;
	if (port_id >= 0) {
		dp = dsa_port_from_netdev(dev);
		if (IS_ERR(dp))
			return;
		if (0)
			dsa_tag = port_id + BIT(11);
		else
			dsa_tag = BIT(port_id);
	}
	for (i = 0; i < CFG_PPE_NUM; i++) {
		for (hash_index = 0; hash_index < hnat_priv->foe_etry_num; hash_index++) {
			entry = hnat_priv->foe_table_cpu[i] + hash_index;
			if (!entry_hnat_is_bound(entry))
				continue;
			match_dev = (IS_IPV4_GRP(entry)) ? entry->ipv4_hnapt.iblk2.dp == gmac :
							   entry->ipv6_5t_route.iblk2.dp == gmac;
			if (match_dev && port_id >= 0) {
				if (0) {
					match_dev = (IS_IPV4_GRP(entry)) ?
						entry->ipv4_hnapt.vlan1 == dsa_tag :
						entry->ipv6_5t_route.vlan1 == dsa_tag;
				} else {
					match_dev = (IS_IPV4_GRP(entry)) ?
						!!(entry->ipv4_hnapt.etype & dsa_tag) :
						!!(entry->ipv6_5t_route.etype & dsa_tag);
				}
			}
			if (match_dev) {
				entry->bfib1.state = INVALID;
				entry->bfib1.time_stamp =
					readl((hnat_priv->fe_base + 0x0010)) & 0xFF;
				total++;
			}
		}
	}
	/* clear HWNAT cache */
	if (total > 0)
		hnat_cache_ebl(1);
}

void foe_clear_all_bind_entries(struct net_device *dev)
{
	int i, hash_index;
	struct foe_entry *entry;

	if (!IS_LAN(dev) && !IS_WAN(dev) &&
	    !find_extif_from_devname(dev->name) &&
	    !dev->netdev_ops->ndo_flow_offload_check)
		return;

	for (i = 0; i < CFG_PPE_NUM; i++) {
		cr_set_field(hnat_priv->ppe_base[i] + PPE_TB_CFG,
			     SMA, SMA_ONLY_FWD_CPU);

		for (hash_index = 0; hash_index < hnat_priv->foe_etry_num; hash_index++) {
			entry = hnat_priv->foe_table_cpu[i] + hash_index;
			if (entry->bfib1.state == BIND) {
				entry->ipv4_hnapt.udib1.state = INVALID;
				entry->ipv4_hnapt.udib1.time_stamp =
					readl((hnat_priv->fe_base + 0x0010)) & 0xFF;
			}
		}
	}

	/* clear HWNAT cache */
	hnat_cache_ebl(1);

	mod_timer(&hnat_priv->hnat_sma_build_entry_timer, jiffies + 3 * HZ);
}

static void gmac_ppe_fwd_enable(struct net_device *dev)
{
	//if (IS_LAN(dev) || IS_GMAC1_MODE)
		set_gmac_ppe_fwd(0, 1);
	//else if (IS_WAN(dev))
		set_gmac_ppe_fwd(1, 1);
}

int nf_hnat_netdevice_event(struct notifier_block *unused, unsigned long event,
			    void *ptr)
{
	struct net_device *dev;

	dev = netdev_notifier_info_to_dev(ptr);

	switch (event) {
	case NETDEV_UP:
		if (!hnat_priv->guest_en) {
			if (!strcmp(dev->name, "ra1") || !strcmp(dev->name, "rax1"))
				break;
		}

		gmac_ppe_fwd_enable(dev);

		extif_set_dev(dev, 1);

		break;
	case NETDEV_GOING_DOWN:
		if (!get_wifi_hook_if_index_from_dev(dev))
			extif_put_dev(dev);

		foe_clear_all_bind_entries(dev);

		break;
	case NETDEV_CHANGE:
		/* Clear PPE entries if the slave of bond device physical link down */
		if (!netif_is_bond_slave(dev) ||
		    (!IS_LAN(dev) && !IS_WAN(dev)))
			break;
		if (netif_carrier_ok(dev))
			break;
		foe_clear_ethdev_bind_entries(dev);
		break;
	case NETDEV_UNREGISTER:
		if (hnat_priv->g_ppdev == dev) {
			hnat_priv->g_ppdev = NULL;
			dev_put(dev);
		}
		if (hnat_priv->g_wandev == dev) {
			hnat_priv->g_wandev = NULL;
			dev_put(dev);
		}

		break;
	case NETDEV_REGISTER:
		if (IS_PPD(dev) && !hnat_priv->g_ppdev)
			hnat_priv->g_ppdev = dev_get_by_name(&init_net, hnat_priv->ppd);
		if (IS_WAN(dev) && !hnat_priv->g_wandev)
			hnat_priv->g_wandev = dev_get_by_name(&init_net, hnat_priv->wan);

		break;
	case MTK_FE_RESET_NAT_DONE:
		pr_info("[%s] HNAT driver starts to do warm init !\n", __func__);
		hnat_warm_init();
		break;
	default:
		break;
	}

	return NOTIFY_DONE;
}

void foe_clear_entry(struct neighbour *neigh)
{
	u32 *daddr = (u32 *)neigh->primary_key;
	unsigned char h_dest[ETH_ALEN];
	struct foe_entry *entry;
	int i, hash_index;
	u32 dip;

	dip = (u32)(*daddr);

	for (i = 0; i < CFG_PPE_NUM; i++) {
		if (!hnat_priv->foe_table_cpu[i])
			continue;

		for (hash_index = 0; hash_index < hnat_priv->foe_etry_num; hash_index++) {
			entry = hnat_priv->foe_table_cpu[i] + hash_index;
			if (entry->bfib1.state == BIND &&
			    entry->ipv4_hnapt.new_dip == ntohl(dip) &&
			    IS_IPV4_HNAPT(entry)) {
				*((u32 *)h_dest) = swab32(entry->ipv4_hnapt.dmac_hi);
				*((u16 *)&h_dest[4]) =
					swab16(entry->ipv4_hnapt.dmac_lo);
				if (!ether_addr_equal(h_dest, neigh->ha)) {
					cr_set_field(hnat_priv->ppe_base[i] + PPE_TB_CFG,
						     SMA, SMA_ONLY_FWD_CPU);

					entry->ipv4_hnapt.udib1.state = INVALID;
					entry->ipv4_hnapt.udib1.time_stamp =
						readl((hnat_priv->fe_base + 0x0010)) & 0xFF;

					/* clear HWNAT cache */
					hnat_cache_ebl(1);

					mod_timer(&hnat_priv->hnat_sma_build_entry_timer,
						  jiffies + 3 * HZ);
					if (debug_level >= 7) {
						pr_info("%s: state=%d\n", __func__,
							neigh->nud_state);
						pr_info("Delete old entry: dip =%pI4\n", &dip);
						pr_info("Old mac= %pM\n", h_dest);
						pr_info("New mac= %pM\n", neigh->ha);
					}
				}
			}
		}
	}
}

int nf_hnat_netevent_handler(struct notifier_block *unused, unsigned long event,
			     void *ptr)
{
	struct net_device *dev = NULL;
	struct neighbour *neigh = NULL;

	switch (event) {
	case NETEVENT_NEIGH_UPDATE:
		neigh = ptr;
		dev = neigh->dev;
		if (dev)
			foe_clear_entry(neigh);
		break;
	}

	return NOTIFY_DONE;
}

unsigned int mape_add_ipv6_hdr(struct sk_buff *skb, struct ipv6hdr mape_ip6h)
{
	struct ethhdr *eth = NULL;
	struct ipv6hdr *ip6h = NULL;
	struct iphdr *iph = NULL;

	if (skb_headroom(skb) < IPV6_HDR_LEN || skb_shared(skb) ||
	    (skb_cloned(skb) && !skb_clone_writable(skb, 0))) {
		return -1;
	}

	/* point to L3 */
	memcpy(skb->data - IPV6_HDR_LEN - ETH_HLEN, skb_push(skb, ETH_HLEN), ETH_HLEN);
	memcpy(skb_push(skb, IPV6_HDR_LEN - ETH_HLEN), &mape_ip6h, IPV6_HDR_LEN);

	eth = (struct ethhdr *)(skb->data - ETH_HLEN);
	eth->h_proto = htons(ETH_P_IPV6);
	skb->protocol = htons(ETH_P_IPV6);

	iph = (struct iphdr *)(skb->data + IPV6_HDR_LEN);
	ip6h = (struct ipv6hdr *)(skb->data);
	ip6h->payload_len = iph->tot_len; /* maybe different with ipv4 */

	skb_set_network_header(skb, 0);
	skb_set_transport_header(skb, iph->ihl * 4 + IPV6_HDR_LEN);
	return 0;
}

static void fix_skb_packet_type(struct sk_buff *skb, struct net_device *dev,
				struct ethhdr *eth)
{
	skb->pkt_type = PACKET_HOST;
	if (unlikely(is_multicast_ether_addr(eth->h_dest))) {
		if (ether_addr_equal_64bits(eth->h_dest, dev->broadcast))
			skb->pkt_type = PACKET_BROADCAST;
		else
			skb->pkt_type = PACKET_MULTICAST;
	}
}

unsigned int do_hnat_ext_to_ge(struct sk_buff *skb, const struct net_device *in,
			       const char *func)
{
	if (hnat_priv->g_ppdev && hnat_priv->g_ppdev->flags & IFF_UP) {
		u16 vlan_id = 0;
		skb_set_network_header(skb, 0);
		skb_push(skb, ETH_HLEN);
		set_to_ppe(skb);

		vlan_id = skb_vlan_tag_get_id(skb);
		if (vlan_id) {
			skb = vlan_insert_tag(skb, skb->vlan_proto, skb->vlan_tci);
			if (!skb)
				return -1;
		}

		/*set where we come from*/
		__vlan_hwaccel_put_tag(skb, htons(ETH_P_8021Q), VLAN_CFI_MASK | (in->ifindex & VLAN_VID_MASK)); 
		trace_printk(
			"%s: vlan_prot=0x%x, vlan_tci=%x, in->name=%s, skb->dev->name=%s\n",
			__func__, ntohs(skb->vlan_proto), skb->vlan_tci,
			in->name, hnat_priv->g_ppdev->name);
		skb->dev = hnat_priv->g_ppdev;
		dev_queue_xmit(skb);
		trace_printk("%s: called from %s successfully\n", __func__, func);
		return 0;
	}

	trace_printk("%s: called from %s fail\n", __func__, func);
	return -1;
}

unsigned int do_hnat_ext_to_ge2(struct sk_buff *skb, const char *func)
{
	struct ethhdr *eth = eth_hdr(skb);
	struct net_device *dev;
	struct foe_entry *entry;
	
	trace_printk("%s: vlan_prot=0x%x, vlan_tci=%x\n", __func__,
		     ntohs(skb->vlan_proto), skb->vlan_tci);

	dev = get_dev_from_index(skb->vlan_tci & VLAN_VID_MASK);

	if (dev) {
		/*set where we to go*/
		skb->dev = dev;
		skb->vlan_proto = 0;
		skb->vlan_tci = 0;
		__vlan_hwaccel_clear_tag(skb);
		if (ntohs(eth->h_proto) == ETH_P_8021Q) {
			skb = skb_vlan_untag(skb);
			if (unlikely(!skb))
				return -1;
		}

		if (IS_BOND(dev) &&
		    (((hnat_priv->data->version == MTK_HNAT_V4) &&
				(skb_hnat_entry(skb) != 0x7fff)) ||
		     ((hnat_priv->data->version != MTK_HNAT_V4) &&
				(skb_hnat_entry(skb) != 0x3fff))))
			skb_set_hash(skb, skb_hnat_entry(skb) >> 1, PKT_HASH_TYPE_L4);

		set_from_extge(skb);
		fix_skb_packet_type(skb, skb->dev, eth); 
		netif_rx(skb);
		trace_printk("%s: called from %s successfully\n", __func__,
			     func);
		return 0;
	} else {
		/* MapE WAN --> LAN/WLAN PingPong. */
		dev = get_wandev_from_index(skb->vlan_tci & VLAN_VID_MASK);
		if (mape_toggle && dev) {
			if (!mape_add_ipv6_hdr(skb, mape_w2l_v6h)) {
				skb_set_mac_header(skb, -ETH_HLEN);
				skb->dev = dev;
				set_from_mape(skb);
				skb->vlan_proto = 0;
				skb->vlan_tci = 0;
				fix_skb_packet_type(skb, skb->dev, eth_hdr(skb));
				entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];
				entry->bfib1.pkt_type = IPV4_HNAPT;
				netif_rx(skb);
				return 0;
			}
		}
		trace_printk("%s: called from %s fail\n", __func__, func);
		return -1;
	}
}

unsigned int do_hnat_ge_to_ext(struct sk_buff *skb, const char *func)
{
	/*set where we to go*/
	u8 index;
	struct foe_entry *entry;
	struct net_device *dev;

 	 
	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];

	if (IS_IPV4_GRP(entry))
		index = entry->ipv4_hnapt.act_dp;
	else
		index = entry->ipv6_5t_route.act_dp;

	dev = get_dev_from_index(index);
	if (!dev) {
		trace_printk("%s: called from %s. Get wifi interface fail\n",
			     __func__, func);
		return 0;
	}

	skb->dev = dev;

	if (IS_HQOS_MODE && eth_hdr(skb)->h_proto == HQOS_MAGIC_TAG) {
		skb = skb_unshare(skb, GFP_ATOMIC);
		if (!skb)
			return NF_ACCEPT;

		if (unlikely(!pskb_may_pull(skb, VLAN_HLEN)))
			return NF_ACCEPT;

		skb_pull_rcsum(skb, VLAN_HLEN);

		memmove(skb->data - ETH_HLEN, skb->data - ETH_HLEN - VLAN_HLEN,
			2 * ETH_ALEN);
	}

	if (skb->dev) {
		skb_set_network_header(skb, 0);
		skb_push(skb, ETH_HLEN);
		dev_queue_xmit(skb);
		trace_printk("%s: called from %s successfully\n", __func__,
			     func);
		return 0;
	} else {
		if (mape_toggle) {
			/* Add ipv6 header mape for lan/wlan -->wan */
			dev = get_wandev_from_index(index);
			if (dev) {
				if (!mape_add_ipv6_hdr(skb, mape_l2w_v6h)) {
					skb_set_network_header(skb, 0);
					skb_push(skb, ETH_HLEN);
					skb_set_mac_header(skb, 0);
					skb->dev = dev;
					dev_queue_xmit(skb);
					return 0;
				}
				trace_printk("%s: called from %s fail[MapE]\n", __func__,
					     func);
				return -1;
			}
		}
	}
	/*if external devices is down, invalidate related ppe entry*/
	if (entry_hnat_is_bound(entry)) {
		entry->bfib1.state = INVALID;
		if (IS_IPV4_GRP(entry))
			entry->ipv4_hnapt.act_dp = 0;
		else
			entry->ipv6_5t_route.act_dp = 0;

		/* clear HWNAT cache */
		hnat_cache_ebl(1);
	}
	trace_printk("%s: called from %s fail, index=%x\n", __func__,
		     func, index);
	return -1;
}

static void pre_routing_print(struct sk_buff *skb, const struct net_device *in,
			      const struct net_device *out, const char *func)
{
	trace_printk(
		"[%s]: %s(iif=0x%x CB2=0x%x)-->%s (ppe_hash=0x%x) sport=0x%x reason=0x%x alg=0x%x from %s\n",
		__func__, in->name, skb_hnat_iface(skb),
		HNAT_SKB_CB2(skb)->magic, out->name, skb_hnat_entry(skb),
		skb_hnat_sport(skb), skb_hnat_reason(skb), skb_hnat_alg(skb),
		func);
}

static void post_routing_print(struct sk_buff *skb, const struct net_device *in,
			       const struct net_device *out, const char *func)
{
	trace_printk(
		"[%s]: %s(iif=0x%x, CB2=0x%x)-->%s (ppe_hash=0x%x) sport=0x%x reason=0x%x alg=0x%x from %s\n",
		__func__, in->name, skb_hnat_iface(skb),
		HNAT_SKB_CB2(skb)->magic, out->name, skb_hnat_entry(skb),
		skb_hnat_sport(skb), skb_hnat_reason(skb), skb_hnat_alg(skb),
		func);
}

static inline void hnat_set_iif(const struct nf_hook_state *state,
				struct sk_buff *skb, int val)
{
	if (IS_WHNAT(state->in) && FROM_WED(skb)) {
		return;
	} else if (IS_LAN(state->in)) {
		skb_hnat_iface(skb) = FOE_MAGIC_GE_LAN;
	} else if (IS_PPD(state->in)) {
		skb_hnat_iface(skb) = FOE_MAGIC_GE_PPD;
	} else if (IS_EXT(state->in)) {
		skb_hnat_iface(skb) = FOE_MAGIC_EXT;
	} else if (IS_WAN(state->in)) {
		skb_hnat_iface(skb) = FOE_MAGIC_GE_WAN;
	} else if (!IS_BR(state->in)) {
		if (state->in->netdev_ops->ndo_flow_offload_check) {
			skb_hnat_iface(skb) = FOE_MAGIC_GE_VIRTUAL;
		} else {
			skb_hnat_iface(skb) = FOE_INVALID;

			if (is_magic_tag_valid(skb) &&
			    IS_SPACE_AVAILABLE_HEAD(skb))
				memset(skb_hnat_info(skb), 0, FOE_INFO_LEN);
		}
	}
}

static inline void hnat_set_alg(const struct nf_hook_state *state,
				struct sk_buff *skb, int val)
{
	skb_hnat_alg(skb) = val;
}

static inline void hnat_set_tag(const struct nf_hook_state *state,
				struct sk_buff *skb, int val)
{
	skb_hnat_magic_tag(skb) = val;
}

static inline void hnat_set_head_frags(const struct nf_hook_state *state,
				       struct sk_buff *head_skb, int val,
				       void (*fn)(const struct nf_hook_state *state,
						  struct sk_buff *skb, int val))
{
	struct sk_buff *segs = skb_shinfo(head_skb)->frag_list;

	fn(state, head_skb, val);
	while (segs) {
		fn(state, segs, val);
		segs = segs->next;
	}
}

static void ppe_fill_flow_lbl(struct foe_entry *entry, struct ipv6hdr *ip6h)
{
	entry->ipv4_dslite.flow_lbl[0] = ip6h->flow_lbl[2];
	entry->ipv4_dslite.flow_lbl[1] = ip6h->flow_lbl[1];
	entry->ipv4_dslite.flow_lbl[2] = ip6h->flow_lbl[0];
}

unsigned int do_hnat_mape_w2l_fast(struct sk_buff *skb, const struct net_device *in,
				   const char *func)
{
	struct ipv6hdr *ip6h = ipv6_hdr(skb);
	struct iphdr _iphdr;
	struct iphdr *iph;
	struct ethhdr *eth;

	/* WAN -> LAN/WLAN MapE. */
	if (mape_toggle && (ip6h->nexthdr == NEXTHDR_IPIP)) {
		iph = skb_header_pointer(skb, IPV6_HDR_LEN, sizeof(_iphdr), &_iphdr);
		if (unlikely(!iph))
			return -1;

		switch (iph->protocol) {
		case IPPROTO_UDP:
		case IPPROTO_TCP:
			break;
		default:
			return -1;
		}
		mape_w2l_v6h = *ip6h;

		/* Remove ipv6 header. */
		memcpy(skb->data + IPV6_HDR_LEN - ETH_HLEN,
		       skb->data - ETH_HLEN, ETH_HLEN);
		skb_pull(skb, IPV6_HDR_LEN - ETH_HLEN);
		skb_set_mac_header(skb, 0);
		skb_set_network_header(skb, ETH_HLEN);
		skb_set_transport_header(skb, ETH_HLEN + sizeof(_iphdr));

		eth = eth_hdr(skb);
		eth->h_proto = htons(ETH_P_IP);
		set_to_ppe(skb);

		__vlan_hwaccel_put_tag(skb, htons(ETH_P_8021Q), VLAN_CFI_MASK | (in->ifindex & VLAN_VID_MASK));

		if (!hnat_priv->g_ppdev)
			hnat_priv->g_ppdev = dev_get_by_name(&init_net, hnat_priv->ppd);

		skb->dev = hnat_priv->g_ppdev;
		skb->protocol = htons(ETH_P_IP);

		dev_queue_xmit(skb);

		return 0;
	}
	return -1;
}

#if defined(CONFIG_MEDIATEK_NETSYS_V2)
unsigned int do_hnat_mape_w2l(struct sk_buff *skb, const struct net_device *in,
				   const char *func)
{
	struct ipv6hdr *ip6h = ipv6_hdr(skb);
	struct iphdr _iphdr;
	struct iphdr *iph;
	struct foe_entry *entry;
	struct tcpudphdr _ports;
	const struct tcpudphdr *pptr;
	int udp = 0;

	/* WAN -> LAN/WLAN MapE learn info(include innner IPv4 header info). */
	if (ip6h->nexthdr == NEXTHDR_IPIP) {
		entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];

		entry->ipv4_dslite.tunnel_sipv6_0 =
			ntohl(ip6h->saddr.s6_addr32[0]);
		entry->ipv4_dslite.tunnel_sipv6_1 =
			ntohl(ip6h->saddr.s6_addr32[1]);
		entry->ipv4_dslite.tunnel_sipv6_2 =
			ntohl(ip6h->saddr.s6_addr32[2]);
		entry->ipv4_dslite.tunnel_sipv6_3 =
			ntohl(ip6h->saddr.s6_addr32[3]);

		entry->ipv4_dslite.tunnel_dipv6_0 =
			ntohl(ip6h->daddr.s6_addr32[0]);
		entry->ipv4_dslite.tunnel_dipv6_1 =
			ntohl(ip6h->daddr.s6_addr32[1]);
		entry->ipv4_dslite.tunnel_dipv6_2 =
			ntohl(ip6h->daddr.s6_addr32[2]);
		entry->ipv4_dslite.tunnel_dipv6_3 =
			ntohl(ip6h->daddr.s6_addr32[3]);

		ppe_fill_flow_lbl(entry, ip6h);

		iph = skb_header_pointer(skb, IPV6_HDR_LEN,
					 sizeof(_iphdr), &_iphdr);
		if (unlikely(!iph))
			return NF_ACCEPT;

		switch (iph->protocol) {
		case IPPROTO_UDP:
			udp = 1;
		case IPPROTO_TCP:
		break;

		default:
			return NF_ACCEPT;
		}

		pptr = skb_header_pointer(skb, IPV6_HDR_LEN + iph->ihl * 4,
					  sizeof(_ports), &_ports);
		if (unlikely(!pptr))
			return NF_ACCEPT;

		entry->bfib1.udp = udp;

		entry->ipv4_dslite.new_sip = ntohl(iph->saddr);
		entry->ipv4_dslite.new_dip = ntohl(iph->daddr);
		entry->ipv4_dslite.new_sport = ntohs(pptr->src);
		entry->ipv4_dslite.new_dport = ntohs(pptr->dst);

		return 0;
	}
	return -1;
}
#endif

static unsigned int is_ppe_support_type(struct sk_buff *skb)
{
	struct ethhdr *eth = NULL;
	struct iphdr *iph = NULL;
	struct ipv6hdr *ip6h = NULL;
	struct iphdr _iphdr;

	eth = eth_hdr(skb);
	if (!is_magic_tag_valid(skb) || !IS_SPACE_AVAILABLE_HEAD(skb) ||
	    is_broadcast_ether_addr(eth->h_dest))
		return 0;

	switch (ntohs(skb->protocol)) {
	case ETH_P_IP:
		iph = ip_hdr(skb);

		/* do not accelerate non tcp/udp traffic */
		if ((iph->protocol == IPPROTO_TCP) ||
		    (iph->protocol == IPPROTO_UDP) ||
		    (iph->protocol == IPPROTO_IPV6)) {
		    
			return 1;
		}

		break;
	case ETH_P_IPV6:
		ip6h = ipv6_hdr(skb);

		if ((ip6h->nexthdr == NEXTHDR_TCP) ||
		    (ip6h->nexthdr == NEXTHDR_UDP)) {
			return 1;
		} else if (ip6h->nexthdr == NEXTHDR_IPIP) {
			iph = skb_header_pointer(skb, IPV6_HDR_LEN,
						 sizeof(_iphdr), &_iphdr);
			if (unlikely(!iph))
				return 0;

			if ((iph->protocol == IPPROTO_TCP) ||
			    (iph->protocol == IPPROTO_UDP)) {
				return 1;
			}

		}

		break;
	case ETH_P_8021Q:
		return 1;
	}
	 
	return 0;
}


static void mtk_hnat_nf_update(struct sk_buff *skb)
{
	struct nf_conn *ct;
	struct nf_conn_acct *acct;
	struct nf_conn_counter *counter;
	enum ip_conntrack_info ctinfo;
	struct hnat_accounting diff;
	
	if (skb->protocol == htons(ETH_P_IPV6) && !hnat_priv->ipv6_en) {
		return ;
	}

	if (skb_hnat_alg(skb) || unlikely(!is_magic_tag_valid(skb) ||
					  !IS_SPACE_AVAILABLE_HEAD(skb)))
		return ;

	if (unlikely(!skb_mac_header_was_set(skb)))
		return ;

	if (unlikely(!skb_hnat_is_hashed(skb)))
		return ;
		
	if (unlikely(skb->mark == HNAT_EXCEPTION_TAG))
		return ;
 
	ct = nf_ct_get(skb, &ctinfo);
	if (ct) {
		if (!hnat_get_count(hnat_priv, skb_hnat_ppe(skb), skb_hnat_entry(skb), &diff))
			return;

		acct = nf_conn_acct_find(ct);
		
		if (acct) {
			counter = acct->counter;
			atomic64_add(diff.packets, &counter[CTINFO2DIR(ctinfo)].packets);
			atomic64_add(diff.bytes, &counter[CTINFO2DIR(ctinfo)].bytes);
			atomic64_set(&counter[CTINFO2DIR(ctinfo)].diff_packets, diff.packets);
			atomic64_set(&counter[CTINFO2DIR(ctinfo)].diff_bytes, diff.bytes);
		}
	}
}


/* update hnat count to nf_conntrack and iptables by keepalive */
static unsigned int
mtk_hnat_nf_conntrack(void *priv, struct sk_buff *skb,
			     const struct nf_hook_state *state)
{
	if (!skb)
		goto drop;
	
	if (unlikely(skb_hnat_reason(skb) == HIT_BIND_KEEPALIVE_DUP_OLD_HDR))
		{
		if (hnat_priv->data->per_flow_accounting && hnat_priv->nf_stat_en)
			mtk_hnat_nf_update(skb);}
		
	return NF_ACCEPT;
	
drop:
	
	return NF_DROP;	

}

static unsigned int
mtk_hnat_ipv6_nf_pre_routing(void *priv, struct sk_buff *skb,
			     const struct nf_hook_state *state)
{
	if (!skb)
		goto drop;

	if (!IS_WHNAT(state->in) && IS_EXT(state->in) && IS_SPACE_AVAILABLE_HEAD(skb)) {
		hnat_set_head_frags(state, skb, 0, hnat_set_alg);
		hnat_set_head_frags(state, skb, HNAT_MAGIC_TAG, hnat_set_alg);
	}

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;

	if (!is_ppe_support_type(skb)) {
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);
		return NF_ACCEPT;
	}

	hnat_set_head_frags(state, skb, -1, hnat_set_iif);

	pre_routing_print(skb, state->in, state->out, __func__);

	/* packets from external devices -> xxx ,step 1 , learning stage & bound stage*/
	if (do_ext2ge_fast_try(state->in, skb)) {
		if (!do_hnat_ext_to_ge(skb, state->in, __func__))
			return NF_STOLEN;
		return NF_ACCEPT;
	}

	/* packets form ge -> external device
	 * For standalone wan interface
	 */
	if (do_ge2ext_fast(state->in, skb)) {
		if (!do_hnat_ge_to_ext(skb, __func__))
			return NF_STOLEN;
		goto drop;
	}

	/* MapE need remove ipv6 header and pingpong. */
	if (do_mape_w2l_fast(state->in, skb)) {
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
		if (mape_toggle && do_hnat_mape_w2l(skb, state->in, __func__))
			return NF_ACCEPT;
#else
		if (!do_hnat_mape_w2l_fast(skb, state->in, __func__))
			return NF_STOLEN;
		else
			return NF_ACCEPT;
#endif
	}

	if (is_from_mape(skb))
		clr_from_extge(skb);

	return NF_ACCEPT;
drop:
	if (skb)
		printk_ratelimited(KERN_WARNING
			"%s:drop (in_dev=%s, iif=0x%x, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, state->in->name, skb_hnat_iface(skb),
			HNAT_SKB_CB2(skb)->magic, skb_hnat_entry(skb),
			skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

/* mtk_hnat_tproxy_connmark_check_v4 was removed (B-013).
 *
 * The function called nf_conntrack_find_get() (hash-table lookup + spinlock)
 * for every HNAT-tagged UDP packet from the bridge, causing CPU saturation
 * under all-port UDP relay (gaming + IoT) and crashing SSR Plus / Xray.
 *
 * The function's stated purpose - zeroing FOE entries for established TPROXY
 * flows before the IP stack sees them - is redundant because:
 *
 *   1. TPROXY flows go to LOCAL_IN, not FORWARD.  HNAT hardware can only BIND
 *      flows it observes on the FORWARD/POSTROUTING path.  A LOCAL_IN (TPROXY)
 *      flow therefore stays UNBIND forever; there is nothing to zero.
 *
 *   2. The IP-layer hook mtk_hnat_tproxy_protection_v4 (priority MANGLE+1 =
 *      -149) already zeros FOE entries for every packet carrying the iptables
 *      TPROXY mark (skb->mark & 0x8000).  That hook is the correct and
 *      sufficient interception point.
 *
 * Removing the bridge hook call eliminates the nf_conntrack_find_get() cost
 * entirely (≈0 overhead for TPROXY UDP flows), restoring UDP stability
 * without any functional regression.
 */


static unsigned int
mtk_hnat_ipv4_nf_pre_routing(void *priv, struct sk_buff *skb,
			     const struct nf_hook_state *state)
{
	struct flow_offload_hw_path hw_path = { .dev = skb->dev,
						.virt_dev = skb->dev,
						.flags = 0 };

	if (!skb)
		goto drop;
		

	if (!IS_WHNAT(state->in) && IS_EXT(state->in) && IS_SPACE_AVAILABLE_HEAD(skb)) {
		hnat_set_head_frags(state, skb, 0, hnat_set_alg);
		hnat_set_head_frags(state, skb, HNAT_MAGIC_TAG, hnat_set_alg);
	}

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;

	if (!is_ppe_support_type(skb)) {
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);
		return NF_ACCEPT;
	}

	hnat_set_head_frags(state, skb, -1, hnat_set_iif);

	if (skb_hnat_iface(skb) == FOE_MAGIC_GE_VIRTUAL
	    && skb->dev->netdev_ops->ndo_flow_offload_check) {
		skb->dev->netdev_ops->ndo_flow_offload_check(&hw_path);

		if (hw_path.flags & FLOW_OFFLOAD_PATH_TNL)
			skb_hnat_alg(skb) = 1;
	}

	pre_routing_print(skb, state->in, state->out, __func__);

	/* packets from external devices -> xxx ,step 1 , learning stage & bound stage*/
	if (do_ext2ge_fast_try(state->in, skb)) {
		if (!do_hnat_ext_to_ge(skb, state->in, __func__))
			return NF_STOLEN;
		return NF_ACCEPT;
	}

	/* packets form ge -> external device
	 * For standalone wan interface
	 */
	if (do_ge2ext_fast(state->in, skb)) {
		if (!do_hnat_ge_to_ext(skb, __func__))
			return NF_STOLEN;
		goto drop;
	}

	return NF_ACCEPT;
drop:
	if (skb)
		printk_ratelimited(KERN_WARNING
			"%s:drop (in_dev=%s, iif=0x%x, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, state->in->name, skb_hnat_iface(skb),
			HNAT_SKB_CB2(skb)->magic, skb_hnat_entry(skb),
			skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int
mtk_hnat_br_nf_local_in(void *priv, struct sk_buff *skb,
			const struct nf_hook_state *state)
{
	struct vlan_ethhdr *veth; 
	if (!skb)
		goto drop;
	
	if (!IS_WHNAT(state->in) && IS_EXT(state->in) && IS_SPACE_AVAILABLE_HEAD(skb)) {
		hnat_set_head_frags(state, skb, 0, hnat_set_alg);
		hnat_set_head_frags(state, skb, HNAT_MAGIC_TAG, hnat_set_alg);
	}

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;
  
	if (IS_HQOS_MODE && hnat_priv->data->whnat) {
		veth = (struct vlan_ethhdr *)skb_mac_header(skb);

		if (eth_hdr(skb)->h_proto == HQOS_MAGIC_TAG) {
			skb_hnat_entry(skb) = ntohs(veth->h_vlan_TCI) & 0x3fff;
			skb_hnat_reason(skb) = HIT_BIND_FORCE_TO_CPU;
		}
	}

	if (!HAS_HQOS_MAGIC_TAG(skb) && !is_ppe_support_type(skb)) {
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);
		return NF_ACCEPT;
	}
 

	hnat_set_head_frags(state, skb, -1, hnat_set_iif);

	pre_routing_print(skb, state->in, state->out, __func__);


	if (unlikely(debug_level >= 7)) {
		hnat_cpu_reason_cnt(skb);
		if (skb_hnat_reason(skb) == dbg_cpu_reason)
			foe_dump_pkt(skb);}

	/* packets from external devices -> xxx ,step 1 , learning stage & bound stage*/
	if ((skb_hnat_iface(skb) == FOE_MAGIC_EXT) && !is_from_extge(skb) &&
	    !is_multicast_ether_addr(eth_hdr(skb)->h_dest)) {
 		
		if (!hnat_priv->g_ppdev)
			hnat_priv->g_ppdev = dev_get_by_name(&init_net, hnat_priv->ppd);

		if (!do_hnat_ext_to_ge(skb, state->in, __func__))
			return NF_STOLEN;
		return NF_ACCEPT;
	}

	if (hnat_priv->data->whnat) {
		if (skb_hnat_iface(skb) == FOE_MAGIC_EXT)
			clr_from_extge(skb);
		
		/* packets from external devices -> xxx ,step 2, learning stage */
		if (do_ext2ge_fast_learn(state->in, skb) && (!qos_toggle ||
		    (qos_toggle && eth_hdr(skb)->h_proto != HQOS_MAGIC_TAG))) {
			if (!do_hnat_ext_to_ge2(skb, __func__))
			{
				return NF_STOLEN;}
			goto drop;
		}

		/* packets form ge -> external device */
		if (do_ge2ext_fast(state->in, skb)) {
			if (!do_hnat_ge_to_ext(skb, __func__))
				return NF_STOLEN;
			goto drop;
		}
	}

	/* MapE need remove ipv6 header and pingpong. (bridge mode) */
	if (do_mape_w2l_fast(state->in, skb)) {
		if (!do_hnat_mape_w2l_fast(skb, state->in, __func__))
			return NF_STOLEN;
		else
			return NF_ACCEPT;
	}

	/* TPROXY FOE zeroing is handled by mtk_hnat_tproxy_protection_v4 at
	 * IP PREROUTING priority MANGLE+1 (-149), after iptables sets the
	 * 0x8000 TPROXY mark.  No bridge-hook interception needed (B-013). */

	return NF_ACCEPT;
drop:
	if (skb)
		printk_ratelimited(KERN_WARNING
			"%s:drop (in_dev=%s, iif=0x%x, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, state->in->name, skb_hnat_iface(skb),
			HNAT_SKB_CB2(skb)->magic, skb_hnat_entry(skb),
			skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int hnat_ipv6_get_nexthop(struct sk_buff *skb,
					  const struct net_device *out,
					  struct flow_offload_hw_path *hw_path)
{
	const struct in6_addr *ipv6_nexthop;
	struct neighbour *neigh = NULL;
	struct dst_entry *dst = skb_dst(skb);
	struct ethhdr *eth;

	if (hw_path->flags & FLOW_OFFLOAD_PATH_PPPOE) {
		memcpy(eth_hdr(skb)->h_source, hw_path->eth_src, ETH_ALEN);
		memcpy(eth_hdr(skb)->h_dest, hw_path->eth_dest, ETH_ALEN);
		return 0;
	}

	rcu_read_lock_bh();
	ipv6_nexthop =
		rt6_nexthop((struct rt6_info *)dst, &ipv6_hdr(skb)->daddr);
	neigh = __ipv6_neigh_lookup_noref(dst->dev, ipv6_nexthop);
	if (unlikely(!neigh)) {
		dev_notice(hnat_priv->dev, "%s:No neigh (daddr=%pI6)\n", __func__,
			   &ipv6_hdr(skb)->daddr);
		rcu_read_unlock_bh();
		return -1;
	}

	/* why do we get all zero ethernet address ? */
	if (!is_valid_ether_addr(neigh->ha)) {
		rcu_read_unlock_bh();
		return -1;
	}

	if (ipv6_hdr(skb)->nexthdr == NEXTHDR_IPIP) {
		/*copy ether type for DS-Lite and MapE */
		eth = (struct ethhdr *)(skb->data - ETH_HLEN);
		eth->h_proto = skb->protocol;
	} else {
		eth = eth_hdr(skb);
	}

	ether_addr_copy(eth->h_dest, neigh->ha);
	ether_addr_copy(eth->h_source, out->dev_addr);

	rcu_read_unlock_bh();

	return 0;
}

static unsigned int hnat_ipv4_get_nexthop(struct sk_buff *skb,
					  const struct net_device *out,
					  struct flow_offload_hw_path *hw_path)
{
	u32 nexthop;
	struct neighbour *neigh;
	struct dst_entry *dst = skb_dst(skb);
	struct rtable *rt = (struct rtable *)dst;
	struct net_device *dev = (__force struct net_device *)out;

	if (hw_path->flags & FLOW_OFFLOAD_PATH_PPPOE) {
		memcpy(eth_hdr(skb)->h_source, hw_path->eth_src, ETH_ALEN);
		memcpy(eth_hdr(skb)->h_dest, hw_path->eth_dest, ETH_ALEN);
		return 0;
	}

	rcu_read_lock_bh();
	nexthop = (__force u32)rt_nexthop(rt, ip_hdr(skb)->daddr);
	neigh = __ipv4_neigh_lookup_noref(dev, nexthop);
	if (unlikely(!neigh)) {
		dev_notice(hnat_priv->dev, "%s:No neigh (daddr=%pI4)\n", __func__,
			   &ip_hdr(skb)->daddr);
		rcu_read_unlock_bh();
		return -1;
	}

	/* why do we get all zero ethernet address ? */
	if (!is_valid_ether_addr(neigh->ha)) {
		rcu_read_unlock_bh();
		return -1;
	}

	memcpy(eth_hdr(skb)->h_dest, neigh->ha, ETH_ALEN);
	memcpy(eth_hdr(skb)->h_source, out->dev_addr, ETH_ALEN);

	rcu_read_unlock_bh();

	return 0;
}

static u16 ppe_get_chkbase(struct iphdr *iph)
{
	u16 org_chksum = ntohs(iph->check);
	u16 org_tot_len = ntohs(iph->tot_len);
	u16 org_id = ntohs(iph->id);
	u16 chksum_tmp, tot_len_tmp, id_tmp;
	u32 tmp = 0;
	u16 chksum_base = 0;

	chksum_tmp = ~(org_chksum);
	tot_len_tmp = ~(org_tot_len);
	id_tmp = ~(org_id);
	tmp = chksum_tmp + tot_len_tmp + id_tmp;
	tmp = ((tmp >> 16) & 0x7) + (tmp & 0xFFFF);
	tmp = ((tmp >> 16) & 0x7) + (tmp & 0xFFFF);
	chksum_base = tmp & 0xFFFF;

	return chksum_base;
}

struct foe_entry ppe_fill_L2_info(struct ethhdr *eth, struct foe_entry entry,
				  struct flow_offload_hw_path *hw_path)
{
	switch (entry.bfib1.pkt_type) {
	case IPV4_HNAPT:
	case IPV4_HNAT:
		entry.ipv4_hnapt.dmac_hi = swab32(*((u32 *)eth->h_dest));
		entry.ipv4_hnapt.dmac_lo = swab16(*((u16 *)&eth->h_dest[4]));
		entry.ipv4_hnapt.smac_hi = swab32(*((u32 *)eth->h_source));
		entry.ipv4_hnapt.smac_lo = swab16(*((u16 *)&eth->h_source[4]));
		entry.ipv4_hnapt.pppoe_id = hw_path->pppoe_sid;
		break;
	case IPV4_DSLITE:
	case IPV4_MAP_E:
	case IPV6_6RD:
	case IPV6_5T_ROUTE:
	case IPV6_3T_ROUTE:
		entry.ipv6_5t_route.dmac_hi = swab32(*((u32 *)eth->h_dest));
		entry.ipv6_5t_route.dmac_lo = swab16(*((u16 *)&eth->h_dest[4]));
		entry.ipv6_5t_route.smac_hi = swab32(*((u32 *)eth->h_source));
		entry.ipv6_5t_route.smac_lo =
			swab16(*((u16 *)&eth->h_source[4]));
		entry.ipv6_5t_route.pppoe_id = hw_path->pppoe_sid;
		break;
	}
	return entry;
}

struct foe_entry ppe_fill_info_blk(struct ethhdr *eth, struct foe_entry entry,
				   struct flow_offload_hw_path *hw_path)
{
	entry.bfib1.psn = (hw_path->flags & FLOW_OFFLOAD_PATH_PPPOE) ? 1 : 0;
	entry.bfib1.vlan_layer += (hw_path->flags & FLOW_OFFLOAD_PATH_VLAN) ? 1 : 0;
	entry.bfib1.vpm = (entry.bfib1.vlan_layer) ? 1 : 0;
	entry.bfib1.cah = 1;
	entry.bfib1.time_stamp = (hnat_priv->data->version == MTK_HNAT_V4) ?
		readl(hnat_priv->fe_base + 0x0010) & (0xFF) :
		readl(hnat_priv->fe_base + 0x0010) & (0x7FFF);

	switch (entry.bfib1.pkt_type) {
	case IPV4_HNAPT:
	case IPV4_HNAT:
		if (hnat_priv->data->mcast &&
		    is_multicast_ether_addr(&eth->h_dest[0])) {
			entry.ipv4_hnapt.iblk2.mcast = 1;
			if (hnat_priv->data->version == MTK_HNAT_V3) {
				entry.bfib1.sta = 1;
				entry.ipv4_hnapt.m_timestamp = foe_timestamp(hnat_priv);
			}
		} else {
			entry.ipv4_hnapt.iblk2.mcast = 0;
		}

		entry.ipv4_hnapt.iblk2.port_ag =
			(hnat_priv->data->version == MTK_HNAT_V4) ? 0xf : 0x3f;
		break;
	case IPV4_DSLITE:
	case IPV4_MAP_E:
	case IPV6_6RD:
	case IPV6_5T_ROUTE:
	case IPV6_3T_ROUTE:
		if (hnat_priv->data->mcast &&
		    is_multicast_ether_addr(&eth->h_dest[0])) {
			entry.ipv6_5t_route.iblk2.mcast = 1;
			if (hnat_priv->data->version == MTK_HNAT_V3) {
				entry.bfib1.sta = 1;
				entry.ipv4_hnapt.m_timestamp = foe_timestamp(hnat_priv);
			}
		} else {
			entry.ipv6_5t_route.iblk2.mcast = 0;
		}

		entry.ipv6_5t_route.iblk2.port_ag =
			(hnat_priv->data->version == MTK_HNAT_V4) ? 0xf : 0x3f;
		break;
	}
	return entry;
}

static unsigned int skb_to_hnat_info(struct sk_buff *skb,
				     const struct net_device *dev,
				     struct foe_entry *foe,
				     struct flow_offload_hw_path *hw_path)
{
	struct foe_entry entry = { 0 };
	int whnat = IS_WHNAT(dev);
	struct ethhdr *eth;
	struct iphdr *iph;
	struct ipv6hdr *ip6h;
	struct tcpudphdr _ports;
	const struct tcpudphdr *pptr;
	struct nf_conn *ct;
	enum ip_conntrack_info ctinfo;
	u32 gmac = NR_DISCARD;
	int udp = 0;
	u32 qid = 0;
	int port_id = 0;
	int mape = 0;
	u8  dscp = 0;
	struct net_device *master_dev = (struct net_device *)dev;
	struct mtk_mac *mac;

	ct = nf_ct_get(skb, &ctinfo);
	

	if (ipv6_hdr(skb)->nexthdr == NEXTHDR_IPIP)
		/* point to ethernet header for DS-Lite and MapE */
		eth = (struct ethhdr *)(skb->data - ETH_HLEN);
	else
		eth = eth_hdr(skb);

	/*do not bind multicast if PPE mcast not enable*/
	if (!hnat_priv->data->mcast && is_multicast_ether_addr(eth->h_dest))
		return 0;

	entry.bfib1.pkt_type = foe->udib1.pkt_type; /* Get packte type state*/
	entry.bfib1.state = foe->udib1.state;

	if (unlikely(entry.bfib1.state != UNBIND))
		return 0;

#if defined(CONFIG_MEDIATEK_NETSYS_V2)
	entry.bfib1.sp = foe->udib1.sp;
#endif

	switch (ntohs(eth->h_proto)) {
	case ETH_P_IP:
		iph = ip_hdr(skb);
		switch (iph->protocol) {
		case IPPROTO_UDP:
			udp = 1;
			/* fallthrough */
		case IPPROTO_TCP:
			entry.ipv4_hnapt.etype = htons(ETH_P_IP);

			/* DS-Lite WAN->LAN */
			if (entry.ipv4_hnapt.bfib1.pkt_type == IPV4_DSLITE ||
			    entry.ipv4_hnapt.bfib1.pkt_type == IPV4_MAP_E) {
				entry.ipv4_dslite.sip = foe->ipv4_dslite.sip;
				entry.ipv4_dslite.dip = foe->ipv4_dslite.dip;
				entry.ipv4_dslite.sport =
					foe->ipv4_dslite.sport;
				entry.ipv4_dslite.dport =
					foe->ipv4_dslite.dport;

#if defined(CONFIG_MEDIATEK_NETSYS_V2)
				if (entry.bfib1.pkt_type == IPV4_MAP_E) {
					pptr = skb_header_pointer(skb,
								  iph->ihl * 4,
								  sizeof(_ports),
								  &_ports);
					if (unlikely(!pptr))
						return -1;

					entry.ipv4_dslite.new_sip =
							ntohl(iph->saddr);
					entry.ipv4_dslite.new_dip =
							ntohl(iph->daddr);
					entry.ipv4_dslite.new_sport =
							ntohs(pptr->src);
					entry.ipv4_dslite.new_dport =
							ntohs(pptr->dst);
				}
#endif

				entry.ipv4_dslite.tunnel_sipv6_0 =
					foe->ipv4_dslite.tunnel_sipv6_0;
				entry.ipv4_dslite.tunnel_sipv6_1 =
					foe->ipv4_dslite.tunnel_sipv6_1;
				entry.ipv4_dslite.tunnel_sipv6_2 =
					foe->ipv4_dslite.tunnel_sipv6_2;
				entry.ipv4_dslite.tunnel_sipv6_3 =
					foe->ipv4_dslite.tunnel_sipv6_3;

				entry.ipv4_dslite.tunnel_dipv6_0 =
					foe->ipv4_dslite.tunnel_dipv6_0;
				entry.ipv4_dslite.tunnel_dipv6_1 =
					foe->ipv4_dslite.tunnel_dipv6_1;
				entry.ipv4_dslite.tunnel_dipv6_2 =
					foe->ipv4_dslite.tunnel_dipv6_2;
				entry.ipv4_dslite.tunnel_dipv6_3 =
					foe->ipv4_dslite.tunnel_dipv6_3;

				entry.ipv4_dslite.bfib1.rmt = 1;
				entry.ipv4_dslite.iblk2.dscp = iph->tos;
				entry.ipv4_dslite.vlan1 = hw_path->vlan_id;
				if (hnat_priv->data->per_flow_accounting)
					entry.ipv4_dslite.iblk2.mibf = 1;

			} else {
				entry.ipv4_hnapt.iblk2.dscp = iph->tos;
				dscp = iph->tos;
				if (hnat_priv->data->per_flow_accounting)
					entry.ipv4_hnapt.iblk2.mibf = 1;

				entry.ipv4_hnapt.vlan1 = hw_path->vlan_id;

				if (skb_vlan_tagged(skb)) {
					entry.bfib1.vlan_layer += 1;

					if (entry.ipv4_hnapt.vlan1)
						entry.ipv4_hnapt.vlan2 =
							skb->vlan_tci;
					else
						entry.ipv4_hnapt.vlan1 =
							skb->vlan_tci;
				}

				entry.ipv4_hnapt.sip = foe->ipv4_hnapt.sip;
				entry.ipv4_hnapt.dip = foe->ipv4_hnapt.dip;
				entry.ipv4_hnapt.sport = foe->ipv4_hnapt.sport;
				entry.ipv4_hnapt.dport = foe->ipv4_hnapt.dport;

				entry.ipv4_hnapt.new_sip = ntohl(iph->saddr);
				entry.ipv4_hnapt.new_dip = ntohl(iph->daddr);
			}

			entry.ipv4_hnapt.bfib1.udp = udp;
			if (IS_IPV4_HNAPT(foe)) {
				pptr = skb_header_pointer(skb, iph->ihl * 4,
							  sizeof(_ports),
							  &_ports);
				if (unlikely(!pptr))
					return -1;

				entry.ipv4_hnapt.new_sport = ntohs(pptr->src);
				entry.ipv4_hnapt.new_dport = ntohs(pptr->dst);
			}

			break;

		default:
			return -1;
		}
		trace_printk(
			"[%s]skb->head=%p, skb->data=%p,ip_hdr=%p, skb->len=%d, skb->data_len=%d\n",
			__func__, skb->head, skb->data, iph, skb->len,
			skb->data_len);
		break;

	case ETH_P_IPV6:
		ip6h = ipv6_hdr(skb);
		switch (ip6h->nexthdr) {
		case NEXTHDR_UDP:
			udp = 1;
			/* fallthrough */
		case NEXTHDR_TCP: /* IPv6-5T or IPv6-3T */
			entry.ipv6_5t_route.etype = htons(ETH_P_IPV6);

			entry.ipv6_5t_route.vlan1 = hw_path->vlan_id;

			if (skb_vlan_tagged(skb)) {
				entry.bfib1.vlan_layer += 1;

				if (entry.ipv6_5t_route.vlan1)
					entry.ipv6_5t_route.vlan2 =
						skb->vlan_tci;
				else
					entry.ipv6_5t_route.vlan1 =
						skb->vlan_tci;
			}

			if (hnat_priv->data->per_flow_accounting)
				entry.ipv6_5t_route.iblk2.mibf = 1;
			entry.ipv6_5t_route.bfib1.udp = udp;

			if (IS_IPV6_6RD(foe)) {
				entry.ipv6_5t_route.bfib1.rmt = 1;
				entry.ipv6_6rd.tunnel_sipv4 =
					foe->ipv6_6rd.tunnel_sipv4;
				entry.ipv6_6rd.tunnel_dipv4 =
					foe->ipv6_6rd.tunnel_dipv4;
			}

			entry.ipv6_3t_route.ipv6_sip0 =
				foe->ipv6_3t_route.ipv6_sip0;
			entry.ipv6_3t_route.ipv6_sip1 =
				foe->ipv6_3t_route.ipv6_sip1;
			entry.ipv6_3t_route.ipv6_sip2 =
				foe->ipv6_3t_route.ipv6_sip2;
			entry.ipv6_3t_route.ipv6_sip3 =
				foe->ipv6_3t_route.ipv6_sip3;

			entry.ipv6_3t_route.ipv6_dip0 =
				foe->ipv6_3t_route.ipv6_dip0;
			entry.ipv6_3t_route.ipv6_dip1 =
				foe->ipv6_3t_route.ipv6_dip1;
			entry.ipv6_3t_route.ipv6_dip2 =
				foe->ipv6_3t_route.ipv6_dip2;
			entry.ipv6_3t_route.ipv6_dip3 =
				foe->ipv6_3t_route.ipv6_dip3;

			if (IS_IPV6_3T_ROUTE(foe)) {
				entry.ipv6_3t_route.prot =
					foe->ipv6_3t_route.prot;
				entry.ipv6_3t_route.hph =
					foe->ipv6_3t_route.hph;
			}

			if (IS_IPV6_5T_ROUTE(foe) || IS_IPV6_6RD(foe)) {
				entry.ipv6_5t_route.sport =
					foe->ipv6_5t_route.sport;
				entry.ipv6_5t_route.dport =
					foe->ipv6_5t_route.dport;
			}

			if (ct && (ct->status & IPS_SRC_NAT)) {
				return -1;
			}

			entry.ipv6_5t_route.iblk2.dscp =
				(ip6h->priority << 4 |
				 (ip6h->flow_lbl[0] >> 4));
			break;

		case NEXTHDR_IPIP:
			if ((!mape_toggle &&
			     entry.bfib1.pkt_type == IPV4_DSLITE) ||
			    (mape_toggle &&
			     entry.bfib1.pkt_type == IPV4_MAP_E)) {
				/* DS-Lite LAN->WAN */
				entry.ipv4_dslite.bfib1.udp =
					foe->ipv4_dslite.bfib1.udp;
				entry.ipv4_dslite.sip = foe->ipv4_dslite.sip;
				entry.ipv4_dslite.dip = foe->ipv4_dslite.dip;
				entry.ipv4_dslite.sport =
					foe->ipv4_dslite.sport;
				entry.ipv4_dslite.dport =
					foe->ipv4_dslite.dport;

				entry.ipv4_dslite.tunnel_sipv6_0 =
					ntohl(ip6h->saddr.s6_addr32[0]);
				entry.ipv4_dslite.tunnel_sipv6_1 =
					ntohl(ip6h->saddr.s6_addr32[1]);
				entry.ipv4_dslite.tunnel_sipv6_2 =
					ntohl(ip6h->saddr.s6_addr32[2]);
				entry.ipv4_dslite.tunnel_sipv6_3 =
					ntohl(ip6h->saddr.s6_addr32[3]);

				entry.ipv4_dslite.tunnel_dipv6_0 =
					ntohl(ip6h->daddr.s6_addr32[0]);
				entry.ipv4_dslite.tunnel_dipv6_1 =
					ntohl(ip6h->daddr.s6_addr32[1]);
				entry.ipv4_dslite.tunnel_dipv6_2 =
					ntohl(ip6h->daddr.s6_addr32[2]);
				entry.ipv4_dslite.tunnel_dipv6_3 =
					ntohl(ip6h->daddr.s6_addr32[3]);

				ppe_fill_flow_lbl(&entry, ip6h);

				entry.ipv4_dslite.priority = ip6h->priority;
				entry.ipv4_dslite.hop_limit = ip6h->hop_limit;
				entry.ipv4_dslite.vlan1 = hw_path->vlan_id;
				if (hnat_priv->data->per_flow_accounting)
					entry.ipv4_dslite.iblk2.mibf = 1;
				/* Map-E LAN->WAN record inner IPv4 header info. */
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
				if (mape_toggle) {
					entry.ipv4_dslite.iblk2.dscp = foe->ipv4_dslite.iblk2.dscp;
					entry.ipv4_dslite.new_sip = foe->ipv4_dslite.new_sip;
					entry.ipv4_dslite.new_dip = foe->ipv4_dslite.new_dip;
					entry.ipv4_dslite.new_sport = foe->ipv4_dslite.new_sport;
					entry.ipv4_dslite.new_dport = foe->ipv4_dslite.new_dport;
				}
#endif
			} else if (mape_toggle &&
				   entry.bfib1.pkt_type == IPV4_HNAPT) {
				/* MapE LAN -> WAN */
				mape = 1;
				entry.ipv4_hnapt.iblk2.dscp =
					foe->ipv4_hnapt.iblk2.dscp;
				dscp = foe->ipv4_hnapt.iblk2.dscp;
				if (hnat_priv->data->per_flow_accounting)
					entry.ipv4_hnapt.iblk2.mibf = 1;

				if (IS_GMAC1_MODE)
					entry.ipv4_hnapt.vlan1 = 1;
				else
					entry.ipv4_hnapt.vlan1 = hw_path->vlan_id;

				entry.ipv4_hnapt.sip = foe->ipv4_hnapt.sip;
				entry.ipv4_hnapt.dip = foe->ipv4_hnapt.dip;
				entry.ipv4_hnapt.sport = foe->ipv4_hnapt.sport;
				entry.ipv4_hnapt.dport = foe->ipv4_hnapt.dport;


				entry.ipv4_hnapt.new_sip =
					foe->ipv4_hnapt.new_sip;
				entry.ipv4_hnapt.new_dip =
					foe->ipv4_hnapt.new_dip;
				entry.ipv4_hnapt.etype = htons(ETH_P_IP);

				if (IS_HQOS_MODE) {
					entry.ipv4_hnapt.iblk2.qid =
						(hnat_priv->data->version == MTK_HNAT_V4) ?
						 skb->mark & 0x7f : skb->mark & 0xf;
					entry.ipv4_hnapt.iblk2.fqos = 1;
				}

				entry.ipv4_hnapt.bfib1.udp =
					foe->ipv4_hnapt.bfib1.udp;

				entry.ipv4_hnapt.new_sport =
					foe->ipv4_hnapt.new_sport;
				entry.ipv4_hnapt.new_dport =
					foe->ipv4_hnapt.new_dport;
				mape_l2w_v6h = *ip6h;
			}
			break;

		default:
			return -1;
		}

		trace_printk(
			"[%s]skb->head=%p, skb->data=%p,ipv6_hdr=%p, skb->len=%d, skb->data_len=%d\n",
			__func__, skb->head, skb->data, ip6h, skb->len,
			skb->data_len);
		break;

	default:
		iph = ip_hdr(skb);
		switch (entry.bfib1.pkt_type) {
		case IPV6_6RD: /* 6RD LAN->WAN */
			entry.ipv6_6rd.ipv6_sip0 = foe->ipv6_6rd.ipv6_sip0;
			entry.ipv6_6rd.ipv6_sip1 = foe->ipv6_6rd.ipv6_sip1;
			entry.ipv6_6rd.ipv6_sip2 = foe->ipv6_6rd.ipv6_sip2;
			entry.ipv6_6rd.ipv6_sip3 = foe->ipv6_6rd.ipv6_sip3;

			entry.ipv6_6rd.ipv6_dip0 = foe->ipv6_6rd.ipv6_dip0;
			entry.ipv6_6rd.ipv6_dip1 = foe->ipv6_6rd.ipv6_dip1;
			entry.ipv6_6rd.ipv6_dip2 = foe->ipv6_6rd.ipv6_dip2;
			entry.ipv6_6rd.ipv6_dip3 = foe->ipv6_6rd.ipv6_dip3;

			entry.ipv6_6rd.sport = foe->ipv6_6rd.sport;
			entry.ipv6_6rd.dport = foe->ipv6_6rd.dport;
			entry.ipv6_6rd.tunnel_sipv4 = ntohl(iph->saddr);
			entry.ipv6_6rd.tunnel_dipv4 = ntohl(iph->daddr);
			entry.ipv6_6rd.hdr_chksum = ppe_get_chkbase(iph);
			entry.ipv6_6rd.flag = (ntohs(iph->frag_off) >> 13);
			entry.ipv6_6rd.ttl = iph->ttl;
			entry.ipv6_6rd.dscp = iph->tos;
			entry.ipv6_6rd.per_flow_6rd_id = 1;
			entry.ipv6_6rd.vlan1 = hw_path->vlan_id;
			if (hnat_priv->data->per_flow_accounting)
				entry.ipv6_6rd.iblk2.mibf = 1;
			break;

		default:
			return -1;
		}
	}

	/* Fill Layer2 Info.*/
	entry = ppe_fill_L2_info(eth, entry, hw_path);

	/* Fill Info Blk*/
	entry = ppe_fill_info_blk(eth, entry, hw_path);

	
	if (IS_LAN(dev) || IS_WAN(dev)) {
		
		port_id = hnat_dsa_get_port(&master_dev);
		if (port_id >= 0) {
			if (hnat_dsa_fill_stag(dev, &entry, hw_path,
					       ntohs(eth->h_proto), mape) < 0)
				return 0;
		}

		mac = netdev_priv(master_dev);
		gmac = (mac->id == 1) ? NR_GMAC2_PORT : NR_GMAC1_PORT;
		 
		if (IS_WAN(dev) && mape_toggle && mape == 1) {
			gmac = NR_PDMA_PORT;
			/* Set act_dp = wan_dev */
			entry.ipv4_hnapt.act_dp = dev->ifindex;
		}
	} else if (IS_EXT(dev) && (FROM_GE_PPD(skb) || FROM_GE_LAN(skb) ||
		   FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb) || FROM_WED(skb) || FROM_EXT(skb))) {
		if (!hnat_priv->data->whnat && IS_GMAC1_MODE) {
			entry.bfib1.vpm = 1;
			entry.bfib1.vlan_layer = 1;

			if (FROM_GE_LAN(skb))
				entry.ipv4_hnapt.vlan1 = 1;
			else if (FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))
				entry.ipv4_hnapt.vlan1 = 2;
		}

		trace_printk("learn of lan or wan(iif=%x) --> %s(ext)\n",
			     skb_hnat_iface(skb), dev->name);
		/* To CPU then stolen by pre-routing hant hook of LAN/WAN
		 * Current setting is PDMA RX.
		 */
		gmac = NR_PDMA_PORT;
		if (IS_IPV4_GRP(foe))
			entry.ipv4_hnapt.act_dp = dev->ifindex;
		else
			entry.ipv6_5t_route.act_dp = dev->ifindex;
	} else {
		printk_ratelimited(KERN_WARNING
					"Unknown case of dp, iif=%x --> %s\n",
					skb_hnat_iface(skb), dev->name);

		return 0;
	}

	if (IS_HQOS_MODE || skb->mark >= MAX_PPPQ_PORT_NUM)
		qid = skb->mark & (MTK_QDMA_TX_MASK);
	else if (IS_PPPQ_MODE && (IS_DSA_1G_LAN(dev) || IS_DSA_WAN(dev)))
		qid = port_id & MTK_QDMA_TX_MASK;
	else
		qid = 0;
	if ((IS_HQOS_MODE) && (dscp!=0) &&(hnat_priv->dscp_en))
		qid = (dscp>>2)& (MTK_QDMA_TX_MASK);
		
	if (IS_IPV4_GRP(foe)) {
		entry.ipv4_hnapt.iblk2.dp = gmac;
		entry.ipv4_hnapt.iblk2.port_mg =
			(hnat_priv->data->version == MTK_HNAT_V1) ? 0x3f : 0;

		if (qos_toggle) {
			if (hnat_priv->data->version == MTK_HNAT_V4) {
				entry.ipv4_hnapt.iblk2.qid = qid & 0x7f;
			} else {
				/* qid[5:0]= port_mg[1:0]+ qid[3:0] */
				entry.ipv4_hnapt.iblk2.qid = qid & 0xf;
				if (hnat_priv->data->version != MTK_HNAT_V1)
					entry.ipv4_hnapt.iblk2.port_mg |=
						((qid >> 4) & 0x3);

				if (((IS_EXT(dev) && (FROM_GE_LAN(skb) ||
				      FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))) ||
				      ((mape_toggle && mape == 1) && !FROM_EXT(skb))) &&
				      (!whnat)) {
					entry.ipv4_hnapt.etype = htons(HQOS_MAGIC_TAG);
					entry.ipv4_hnapt.vlan1 = skb_hnat_entry(skb);
					entry.bfib1.vlan_layer = 1;
				}
			}

			if (FROM_EXT(skb) || skb_hnat_sport(skb) == NR_QDMA_PORT ||
			    (IS_PPPQ_MODE && !IS_DSA_LAN(dev) && !IS_DSA_WAN(dev)))
				entry.ipv4_hnapt.iblk2.fqos = 0;
			else
				entry.ipv4_hnapt.iblk2.fqos =
					(!IS_PPPQ_MODE || (IS_PPPQ_MODE &&
					 (IS_DSA_1G_LAN(dev) || IS_DSA_WAN(dev))));
		} else {
			entry.ipv4_hnapt.iblk2.fqos = 0;
		}

		/* [VIP-EGRESS-MARK] WAN egress DSCP re-marking for upload.
		 * fqos==1 guards LAN→WAN direction only (FROM_EXT packets
		 * already set fqos=0, so WAN→LAN downloads are never touched).
		 *
		 * qid  0    : VIP device (all proto)        → EF   (DSCP 46, 0xB8)
		 * qid  1    : 109 UDP≤300B gaming           → EF   (DSCP 46, 0xB8)
		 * qid  2-30 : per-user hash WRR             → AF41 (DSCP 34, 0x88)
		 * qid  31   : rate-limited device           → BE   (DSCP  0, 0x00)
		 */
		if (IS_HQOS_MODE && hnat_priv->dscp_en &&
		    entry.ipv4_hnapt.iblk2.fqos) {
			__be32 _sip = htonl(foe->ipv4_hnapt.sip);
			__be32 _dip = htonl(foe->ipv4_hnapt.dip);
			if (qid == 0) {
				entry.ipv4_hnapt.iblk2.dscp = 0xB8; /* EF = 46<<2 */
				pr_debug("[HNAT-WAN-UP] VIP-Q0 src=%pI4 dst=%pI4 proto=%u "
					 "mark=0x%x→EF(0xB8) foe=%u\n",
					 &_sip, &_dip, iph->protocol,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid == 1) {
				entry.ipv4_hnapt.iblk2.dscp = 0xB8; /* EF = 46<<2 */
				pr_debug("[HNAT-WAN-UP] 109-UDP-VIP-Q1 src=%pI4 dst=%pI4 "
					 "mark=0x%x→EF(0xB8) foe=%u\n",
					 &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid >= 2 && qid <= 30) {
				entry.ipv4_hnapt.iblk2.dscp = 0x88; /* AF41 = 34<<2 */
				pr_debug("[HNAT-WAN-UP] USER-WRR-Q%u src=%pI4 dst=%pI4 "
					 "mark=0x%x→AF41(0x88) foe=%u\n",
					 qid, &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid == 31) {
				entry.ipv4_hnapt.iblk2.dscp = 0x00; /* BE = 0 */
				pr_debug("[HNAT-WAN-UP] RATE-LIM-Q31 src=%pI4 dst=%pI4 "
					 "mark=0x%x→BE(0x00) foe=%u\n",
					 &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else {
				pr_debug("[HNAT-WAN-UP] UNKNOWN-Q%u src=%pI4 dst=%pI4 "
					 "mark=0x%x no-DSCP foe=%u\n",
					 qid, &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			}
		}

		/* [LAN-EGRESS-MARK] LAN egress DSCP re-marking for download.
		 * Applies when qid is in the download range (32-63), meaning
		 * the device was managed by eqos and got a proper download qid.
		 *
		 * qid  32   : VIP device download           → EF   (DSCP 46, 0xB8)
		 * qid  33   : 109 UDP≤300B gaming download  → EF   (DSCP 46, 0xB8)
		 * qid  34-62: per-user hash WRR download    → AF41 (DSCP 34, 0x88)
		 * qid  63   : rate-limited device download  → BE   (DSCP  0, 0x00)
		 */
		if (IS_HQOS_MODE && hnat_priv->dscp_en &&
		    qid >= 32 && qid <= 63) {
			__be32 _sip = htonl(foe->ipv4_hnapt.sip);
			__be32 _dip = htonl(foe->ipv4_hnapt.dip);
			if (qid == 32) {
				entry.ipv4_hnapt.iblk2.dscp = 0xB8; /* EF = 46<<2 */
				pr_debug("[HNAT-LAN-DN] VIP-Q32 src=%pI4 dst=%pI4 "
					 "mark=0x%x→EF(0xB8) foe=%u\n",
					 &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid == 33) {
				entry.ipv4_hnapt.iblk2.dscp = 0xB8; /* EF = 46<<2 */
				pr_debug("[HNAT-LAN-DN] 109-UDP-VIP-Q33 src=%pI4 dst=%pI4 "
					 "mark=0x%x→EF(0xB8) foe=%u\n",
					 &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid >= 34 && qid <= 62) {
				entry.ipv4_hnapt.iblk2.dscp = 0x88; /* AF41 = 34<<2 */
				pr_debug("[HNAT-LAN-DN] USER-WRR-Q%u src=%pI4 dst=%pI4 "
					 "mark=0x%x→AF41(0x88) foe=%u\n",
					 qid, &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else if (qid == 63) {
				entry.ipv4_hnapt.iblk2.dscp = 0x00; /* BE = 0 */
				pr_debug("[HNAT-LAN-DN] RATE-LIM-Q63 src=%pI4 dst=%pI4 "
					 "mark=0x%x→BE(0x00) foe=%u\n",
					 &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			} else {
				pr_debug("[HNAT-LAN-DN] UNKNOWN-Q%u src=%pI4 dst=%pI4 "
					 "mark=0x%x no-DSCP foe=%u\n",
					 qid, &_sip, &_dip,
					 skb->mark, skb_hnat_entry(skb));
			}
		}
	} else {
		entry.ipv6_5t_route.iblk2.dp = gmac;
		entry.ipv6_5t_route.iblk2.port_mg =
			(hnat_priv->data->version == MTK_HNAT_V1) ? 0x3f : 0;

		if (qos_toggle) {
			if (hnat_priv->data->version == MTK_HNAT_V4) {
				entry.ipv6_5t_route.iblk2.qid = qid & 0x7f;
			} else {
				/* qid[5:0]= port_mg[1:0]+ qid[3:0] */
				entry.ipv6_5t_route.iblk2.qid = qid & 0xf;
				if (hnat_priv->data->version != MTK_HNAT_V1)
					entry.ipv6_5t_route.iblk2.port_mg |=
								((qid >> 4) & 0x3);

				if (IS_EXT(dev) && (FROM_GE_LAN(skb) ||
				    FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb)) &&
				    (!whnat)) {
					entry.ipv6_5t_route.etype = htons(HQOS_MAGIC_TAG);
					entry.ipv6_5t_route.vlan1 = skb_hnat_entry(skb);
					entry.bfib1.vlan_layer = 1;
				}
			}

			if (FROM_EXT(skb) ||
			    (IS_PPPQ_MODE && !IS_DSA_LAN(dev) && !IS_DSA_WAN(dev)))
				entry.ipv6_5t_route.iblk2.fqos = 0;
			else
				entry.ipv6_5t_route.iblk2.fqos =
					(!IS_PPPQ_MODE || (IS_PPPQ_MODE &&
					 (IS_DSA_1G_LAN(dev) || IS_DSA_WAN(dev))));
		} else {
			entry.ipv6_5t_route.iblk2.fqos = 0;
		}

		/* [IPv6 QID log] Log which queue this IPv6 flow is assigned to.
		 * qid comes from skb->mark set by eqos/iptables before this hook.
		 * IPv6 default    : Q2  (upload) / Q34 (download)
		 * IPv6 rate-limit : Q31 (upload) / Q63 (download)
		 * fqos=0 means WAN→LAN download or external packet.
		 */
		if (IS_HQOS_MODE && hnat_priv->dscp_en && qos_toggle) {
			/* Reconstruct IPv6 src/dst addresses from FOE u32 fields.
			 * FOE stores them in host byte order; htonl() converts to
			 * network byte order required by %pI6c.
			 */
			struct in6_addr _sip6 = {}, _dip6 = {};
			u8 _fqos;

			_sip6.in6_u.u6_addr32[0] = htonl(foe->ipv6_5t_route.ipv6_sip0);
			_sip6.in6_u.u6_addr32[1] = htonl(foe->ipv6_5t_route.ipv6_sip1);
			_sip6.in6_u.u6_addr32[2] = htonl(foe->ipv6_5t_route.ipv6_sip2);
			_sip6.in6_u.u6_addr32[3] = htonl(foe->ipv6_5t_route.ipv6_sip3);
			_dip6.in6_u.u6_addr32[0] = htonl(foe->ipv6_5t_route.ipv6_dip0);
			_dip6.in6_u.u6_addr32[1] = htonl(foe->ipv6_5t_route.ipv6_dip1);
			_dip6.in6_u.u6_addr32[2] = htonl(foe->ipv6_5t_route.ipv6_dip2);
			_dip6.in6_u.u6_addr32[3] = htonl(foe->ipv6_5t_route.ipv6_dip3);
			_fqos = entry.ipv6_5t_route.iblk2.fqos;

			if (qid == 2) {
				pr_debug("[HNAT-V6-UP] DEFAULT-Q2 src=%pI6c dst=%pI6c mark=0x%x fqos=%u foe=%u\n",
					 &_sip6, &_dip6, skb->mark, _fqos, skb_hnat_entry(skb));
			} else if (qid == 31) {
				pr_debug("[HNAT-V6-UP] RATE-LIM-Q31 src=%pI6c dst=%pI6c mark=0x%x fqos=%u foe=%u\n",
					 &_sip6, &_dip6, skb->mark, _fqos, skb_hnat_entry(skb));
			} else if (qid == 34) {
				pr_debug("[HNAT-V6-DN] DEFAULT-Q34 src=%pI6c dst=%pI6c mark=0x%x fqos=%u foe=%u\n",
					 &_sip6, &_dip6, skb->mark, _fqos, skb_hnat_entry(skb));
			} else if (qid == 63) {
				pr_debug("[HNAT-V6-DN] RATE-LIM-Q63 src=%pI6c dst=%pI6c mark=0x%x fqos=%u foe=%u\n",
					 &_sip6, &_dip6, skb->mark, _fqos, skb_hnat_entry(skb));
			} else {
				pr_debug("[HNAT-V6] Q%u src=%pI6c dst=%pI6c mark=0x%x fqos=%u foe=%u\n",
					 qid, &_sip6, &_dip6, skb->mark, _fqos, skb_hnat_entry(skb));
			}
		}
	}

	/* The INFO2.port_mg and 2nd VLAN ID fields of PPE entry are redefined
	 * by Wi-Fi whnat engine. These data and INFO2.dp will be updated and
	 * the entry is set to BIND state in mtk_sw_nat_hook_tx().
	 */
	if (!whnat) {
		entry.bfib1.ttl = 1;
		entry.bfib1.state = BIND;
	}
 

	wmb();
	memcpy(foe, &entry, sizeof(entry));
	/*reset statistic for this entry*/
	if (hnat_priv->data->per_flow_accounting)
		memset(&hnat_priv->acct[skb_hnat_ppe(skb)][skb_hnat_entry(skb)],
		       0, sizeof(struct mib_entry));

	skb_hnat_filled(skb) = HNAT_INFO_FILLED;

	return 0;
}

int mtk_sw_nat_hook_tx(struct sk_buff *skb, int gmac_no)
{
	struct foe_entry *entry;
	struct ethhdr *eth;
	struct hnat_bind_info_blk bfib1_tx;

	if (skb_hnat_alg(skb) || !is_hnat_info_filled(skb) ||
	    !is_magic_tag_valid(skb) || !IS_SPACE_AVAILABLE_HEAD(skb))
		return NF_ACCEPT;

	trace_printk(
		"[%s]entry=%x reason=%x gmac_no=%x wdmaid=%x rxid=%x wcid=%x bssid=%x\n",
		__func__, skb_hnat_entry(skb), skb_hnat_reason(skb), gmac_no,
		skb_hnat_wdma_id(skb), skb_hnat_bss_id(skb),
		skb_hnat_wc_id(skb), skb_hnat_rx_id(skb));

	if ((gmac_no != NR_WDMA0_PORT) && (gmac_no != NR_WDMA1_PORT) &&
	    (gmac_no != NR_WHNAT_WDMA_PORT))
		return NF_ACCEPT;

	if (unlikely(!skb_mac_header_was_set(skb)))
		return NF_ACCEPT;

	if (!skb_hnat_is_hashed(skb))
		return NF_ACCEPT;
	
	if (skb_hnat_entry(skb) >= hnat_priv->foe_etry_num ||
	    skb_hnat_ppe(skb) >= CFG_PPE_NUM)
		return NF_ACCEPT;

	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];
	spin_lock(&hnat_priv->entry_lock);
	
	if (entry_hnat_is_bound(entry))
		{spin_unlock(&hnat_priv->entry_lock);
		return NF_ACCEPT;
		}

	if (skb_hnat_reason(skb) != HIT_UNBIND_RATE_REACH)
		{spin_unlock(&hnat_priv->entry_lock);
		return NF_ACCEPT;
		}

	eth = eth_hdr(skb);
	memcpy(&bfib1_tx, &entry->bfib1, sizeof(entry->bfib1));

	/*not bind multicast if PPE mcast not enable*/
	if (!hnat_priv->data->mcast) {
		if (is_multicast_ether_addr(eth->h_dest))
			{spin_unlock(&hnat_priv->entry_lock);
			return NF_ACCEPT;
			}	

		if (IS_IPV4_GRP(entry))
			entry->ipv4_hnapt.iblk2.mcast = 0;
		else
			entry->ipv6_5t_route.iblk2.mcast = 0;
	}

	/* Some mt_wifi virtual interfaces, such as apcli,
	 * will change the smac for specail purpose.
	 */
	switch (bfib1_tx.pkt_type) {
	case IPV4_HNAPT:
	case IPV4_HNAT:
		entry->ipv4_hnapt.smac_hi = swab32(*((u32 *)eth->h_source));
		entry->ipv4_hnapt.smac_lo = swab16(*((u16 *)&eth->h_source[4]));
		break;
	case IPV4_DSLITE:
	case IPV4_MAP_E:
	case IPV6_6RD:
	case IPV6_5T_ROUTE:
	case IPV6_3T_ROUTE:
		entry->ipv6_5t_route.smac_hi = swab32(*((u32 *)eth->h_source));
		entry->ipv6_5t_route.smac_lo = swab16(*((u16 *)&eth->h_source[4]));
		break;
	}

	if (skb_vlan_tagged(skb)) {
		bfib1_tx.vlan_layer = 1;
		bfib1_tx.vpm = 1;
		if (IS_IPV4_GRP(entry)) {
			entry->ipv4_hnapt.etype = htons(ETH_P_8021Q);
			entry->ipv4_hnapt.vlan1 = skb->vlan_tci;
		} else if (IS_IPV6_GRP(entry)) {
			entry->ipv6_5t_route.etype = htons(ETH_P_8021Q);
			entry->ipv6_5t_route.vlan1 = skb->vlan_tci;
		}
	} else {
		bfib1_tx.vpm = 0;
		bfib1_tx.vlan_layer = 0;
	}

	/* MT7622 wifi hw_nat not support QoS */
	if (IS_IPV4_GRP(entry)) {
		entry->ipv4_hnapt.iblk2.fqos = 0;
		if ((hnat_priv->data->version == MTK_HNAT_V2 &&
		     gmac_no == NR_WHNAT_WDMA_PORT) ||
		    (hnat_priv->data->version == MTK_HNAT_V4 &&
		     (gmac_no == NR_WDMA0_PORT || gmac_no == NR_WDMA1_PORT))) {
			entry->ipv4_hnapt.winfo.bssid = skb_hnat_bss_id(skb);
			entry->ipv4_hnapt.winfo.wcid = skb_hnat_wc_id(skb);
			entry->ipv4_hnapt.iblk2.fqos = (IS_HQOS_MODE) ? 1 : 0;
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
			entry->ipv4_hnapt.iblk2.rxid = skb_hnat_rx_id(skb);
			entry->ipv4_hnapt.iblk2.winfoi = 1;
#else
			entry->ipv4_hnapt.winfo.rxid = skb_hnat_rx_id(skb);
			entry->ipv4_hnapt.iblk2w.winfoi = 1;
			entry->ipv4_hnapt.iblk2w.wdmaid = skb_hnat_wdma_id(skb);
#endif
		} else {
			if (IS_GMAC1_MODE && !hnat_dsa_is_enable(hnat_priv)) {
				bfib1_tx.vpm = 1;
				bfib1_tx.vlan_layer = 1;

				if (FROM_GE_LAN(skb))
					entry->ipv4_hnapt.vlan1 = 1;
				else if (FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))
					entry->ipv4_hnapt.vlan1 = 2;
			}

			if (IS_HQOS_MODE &&
			    (FROM_GE_LAN(skb) || FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))) {
				bfib1_tx.vpm = 0;
				bfib1_tx.vlan_layer = 1;
				entry->ipv4_hnapt.etype = htons(HQOS_MAGIC_TAG);
				entry->ipv4_hnapt.vlan1 = skb_hnat_entry(skb);
				entry->ipv4_hnapt.iblk2.fqos = 1;
			}
		}
		entry->ipv4_hnapt.iblk2.dp = gmac_no;
	} else {
		entry->ipv6_5t_route.iblk2.fqos = 0;
		if ((hnat_priv->data->version == MTK_HNAT_V2 &&
		     gmac_no == NR_WHNAT_WDMA_PORT) ||
		    (hnat_priv->data->version == MTK_HNAT_V4 &&
		     (gmac_no == NR_WDMA0_PORT || gmac_no == NR_WDMA1_PORT))) {
			entry->ipv6_5t_route.winfo.bssid = skb_hnat_bss_id(skb);
			entry->ipv6_5t_route.winfo.wcid = skb_hnat_wc_id(skb);
			entry->ipv6_5t_route.iblk2.fqos = (IS_HQOS_MODE) ? 1 : 0;
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
			entry->ipv6_5t_route.iblk2.rxid = skb_hnat_rx_id(skb);
			entry->ipv6_5t_route.iblk2.winfoi = 1;
#else
			entry->ipv6_5t_route.winfo.rxid = skb_hnat_rx_id(skb);
			entry->ipv6_5t_route.iblk2w.winfoi = 1;
			entry->ipv6_5t_route.iblk2w.wdmaid = skb_hnat_wdma_id(skb);
#endif
		} else {
			if (IS_GMAC1_MODE && !hnat_dsa_is_enable(hnat_priv)) {
				bfib1_tx.vpm = 1;
				bfib1_tx.vlan_layer = 1;

				if (FROM_GE_LAN(skb))
					entry->ipv6_5t_route.vlan1 = 1;
				else if (FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))
					entry->ipv6_5t_route.vlan1 = 2;
			}

			if (IS_HQOS_MODE &&
			    (FROM_GE_LAN(skb) || FROM_GE_WAN(skb) || FROM_GE_VIRTUAL(skb))) {
				bfib1_tx.vpm = 0;
				bfib1_tx.vlan_layer = 1;
				entry->ipv6_5t_route.etype = htons(HQOS_MAGIC_TAG);
				entry->ipv6_5t_route.vlan1 = skb_hnat_entry(skb);
				entry->ipv6_5t_route.iblk2.fqos = 1;
			}
		}
		entry->ipv6_5t_route.iblk2.dp = gmac_no;
	}

	bfib1_tx.ttl = 1;
	bfib1_tx.state = BIND;
	wmb();
	memcpy(&entry->bfib1, &bfib1_tx, sizeof(bfib1_tx));
	spin_unlock(&hnat_priv->entry_lock);
	return NF_ACCEPT;
}

int mtk_sw_nat_hook_rx(struct sk_buff *skb)
{
	if (!IS_SPACE_AVAILABLE_HEAD(skb) || !FROM_WED(skb)) {
		skb_hnat_magic_tag(skb) = 0;
		return NF_ACCEPT;
	}

	skb_hnat_alg(skb) = 0;
	skb_hnat_filled(skb) = 0;
	skb_hnat_magic_tag(skb) = HNAT_MAGIC_TAG;

	if (skb_hnat_iface(skb) == FOE_MAGIC_WED0)
		skb_hnat_sport(skb) = NR_WDMA0_PORT;
	else if (skb_hnat_iface(skb) == FOE_MAGIC_WED1)
		skb_hnat_sport(skb) = NR_WDMA1_PORT;

	return NF_ACCEPT;
}

void mtk_ppe_dev_register_hook(struct net_device *dev)
{
	int i, number = 0;
	struct extdev_entry *ext_entry;

	if (!hnat_priv->guest_en) {
		if (!strcmp(dev->name, "ra1") || !strcmp(dev->name, "rax1"))
			return;
	}

	for (i = 1; i < MAX_IF_NUM; i++) {
		if (hnat_priv->wifi_hook_if[i] == dev) {
			pr_info("%s : %s has been registered in wifi_hook_if table[%d]\n",
				__func__, dev->name, i);
			return;
		}
	}

	for (i = 1; i < MAX_IF_NUM; i++) {
		if (!hnat_priv->wifi_hook_if[i]) {
			if (find_extif_from_devname(dev->name)) {
				extif_set_dev(dev, 0);
				goto add_wifi_hook_if;
			}

			number = get_ext_device_number();
			if (number >= MAX_EXT_DEVS) {
				pr_info("%s : extdev array is full. %s is not registered\n",
					__func__, dev->name);
				return;
			}

			ext_entry = kzalloc(sizeof(*ext_entry), GFP_KERNEL);
			if (!ext_entry)
				return;

			strncpy(ext_entry->name, dev->name, IFNAMSIZ - 1);
			dev_hold(dev);
			ext_entry->dev = dev;
			ext_if_add(ext_entry);

add_wifi_hook_if:
			dev_hold(dev);
			hnat_priv->wifi_hook_if[i] = dev;

			break;
		}
	}
	pr_info("%s : ineterface %s register (%d)\n", __func__, dev->name, i);
}

void mtk_ppe_dev_unregister_hook(struct net_device *dev)
{
	int i;

	for (i = 1; i < MAX_IF_NUM; i++) {
		if (hnat_priv->wifi_hook_if[i] == dev) {
			hnat_priv->wifi_hook_if[i] = NULL;
			dev_put(dev);

			break;
		}
	}

	extif_put_dev(dev);
	pr_info("%s : ineterface %s set null (%d)\n", __func__, dev->name, i);
}

static unsigned int mtk_hnat_accel_type(struct sk_buff *skb)
{
	struct dst_entry *dst;
	struct nf_conn *ct;
	enum ip_conntrack_info ctinfo;
	const struct nf_conn_help *help;

	/* Do not accelerate 1st round of xfrm flow, and 2nd round of xfrm flow
	 * is from local_out which is also filtered in sanity check.
	 */
	dst = skb_dst(skb);
	if (dst && dst_xfrm(dst))
		return 0;

	ct = nf_ct_get(skb, &ctinfo);
	if (!ct)
		return 1;

	/* rcu_read_lock()ed by nf_hook_slow */
	help = nfct_help(ct);
	if (help && rcu_dereference(help->helper))
		return 0;

	return 1;
}

static u32 hnat_hqos_ipv4_qid(struct foe_entry *entry)
{
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
	return entry->ipv4_hnapt.iblk2.qid & MTK_QDMA_TX_MASK;
#else
	if (hnat_priv->data->version == MTK_HNAT_V1)
		return entry->ipv4_hnapt.iblk2.qid & 0xf;

	return (entry->ipv4_hnapt.iblk2.qid & 0xf) |
	       ((entry->ipv4_hnapt.iblk2.port_mg & 0x3) << 4);
#endif
}

static bool hnat_hqos_ipv4_queue_matches(struct sk_buff *skb,
					 struct foe_entry *entry,
					 const struct iphdr *iph)
{
	u32 entry_qid = hnat_hqos_ipv4_qid(entry);
	u32 skb_qid;

	/*
	 * In the KEEPALIVE_DUP_OLD_HDR path the skb has gone through iptables
	 * mangle FORWARD, so the DSCP rules have rewritten iph->tos to our
	 * internal QoS value (e.g. DSCP=5 → tos=0x14 for Q5 WRR).  For most
	 * flows the comparison (iph->tos >> 2) == entry_qid is correct.
	 *
	 * Exception: VIP Q0 uses DSCP=0 → tos=0 after FORWARD.  The original
	 * fallback "skb_qid = skb->mark & mask" works when skb->mark=0, but
	 * CONNMARK --restore-mark in PREROUTING could restore a non-zero
	 * ct->mark into skb->mark, causing a spurious mismatch for Q0 entries.
	 *
	 * Fast-return true when tos==0: entry_qid must also be 0 (DSCP=0 only
	 * maps to Q0), so the result is always "match" — no false invalidation.
	 */
	if (!iph->tos) {
		pr_debug("[HNAT-QM] tos=0 VIP-Q0 fast-match: entry_qid=%u foe_idx=%u\n",
			 entry_qid, skb_hnat_entry(skb));
		return true;
	}

	skb_qid = (iph->tos >> 2) & MTK_QDMA_TX_MASK;
	pr_debug("[HNAT-QM] tos=0x%02x skb_qid=%u entry_qid=%u %s foe_idx=%u\n",
		 iph->tos, skb_qid, entry_qid,
		 (entry_qid == skb_qid) ? "MATCH" : "MISMATCH-evict",
		 skb_hnat_entry(skb));
	return entry_qid == skb_qid;
}

static void mtk_hnat_dscp_update(struct sk_buff *skb, struct foe_entry *entry)
{
	struct iphdr *iph;
	struct ethhdr *eth;
	struct ipv6hdr *ip6h;
	bool flag = false;

	eth = eth_hdr(skb);
	switch (ntohs(eth->h_proto)) {
	case ETH_P_IP:
		iph = ip_hdr(skb);
		if (IS_IPV4_GRP(entry)) {
			if (IS_HQOS_MODE && hnat_priv->dscp_en) {
				/* Stable QID comparison for both TCP and UDP.
				 * SSR Plus tproxy-intercepted UDP is protected by the
				 * connmark double-lock (mtk_hnat_tproxy_connmark_check_v4
				 * at INT_MIN+1 and mtk_hnat_tproxy_protection_v4 at
				 * NF_IP_PRI_MANGLE+1), which fires after xt_TPROXY sets
				 * skb->mark=0x8000, zeroing the FOE entry for those flows
				 * so HNAT never stably binds them.  Non-SSR UDP flows
				 * (gaming, DNS, etc.) reach BIND normally and are
				 * hardware-accelerated with correct QID assignment.
				 */
				if (!hnat_hqos_ipv4_queue_matches(skb, entry, iph)) {
					pr_debug("[HNAT-DSCP-V4] QID mismatch→evict foe_idx=%u tos=0x%02x\n",
						 skb_hnat_entry(skb), iph->tos);
					flag = true;
				}
			} else if (entry->ipv4_hnapt.iblk2.dscp != iph->tos) {
				pr_debug("[HNAT-DSCP-V4] DSCP mismatch→evict foe_idx=%u entry_dscp=0x%02x iph_tos=0x%02x\n",
					 skb_hnat_entry(skb),
					 entry->ipv4_hnapt.iblk2.dscp, iph->tos);
				flag = true;
			}
		}
		break;
	case ETH_P_IPV6:
		ip6h = ipv6_hdr(skb);
		if ((IS_IPV6_3T_ROUTE(entry) || IS_IPV6_5T_ROUTE(entry)) &&
			(entry->ipv6_5t_route.iblk2.dscp !=
			(ip6h->priority << 4 | (ip6h->flow_lbl[0] >> 4)))) {
			pr_debug("[HNAT-DSCP-V6] DSCP mismatch→evict foe_idx=%u entry_dscp=0x%02x ip6_dscp=0x%02x\n",
				 skb_hnat_entry(skb),
				 entry->ipv6_5t_route.iblk2.dscp,
				 (ip6h->priority << 4 | (ip6h->flow_lbl[0] >> 4)));
			flag = true;
		}
		break;
	default:
		return;
	}

	if (flag) {
		if (debug_level >= 2)
			pr_info("Delete entry idx=%d.\n", skb_hnat_entry(skb));
		memset(entry, 0, sizeof(struct foe_entry));
		hnat_cache_ebl(1);
	}
}

static unsigned int mtk_hnat_nf_post_routing(
	struct sk_buff *skb, const struct net_device *out,
	unsigned int (*fn)(struct sk_buff *, const struct net_device *,
			   struct flow_offload_hw_path *),
	const char *func)
{
	struct foe_entry *entry;
	struct flow_offload_hw_path hw_path = { .dev = (struct net_device*)out,
						.virt_dev = (struct net_device*)out,
						.flags = 0,
						.skb_hash = skb_hnat_entry(skb) };
	const struct net_device *arp_dev = out;
	

	if (skb->protocol == htons(ETH_P_IPV6) && !hnat_priv->ipv6_en) {
		return 0;
	}


	if (skb_hnat_alg(skb) || unlikely(!is_magic_tag_valid(skb) ||
					  !IS_SPACE_AVAILABLE_HEAD(skb)))
		return 0;

	if (unlikely(!skb_mac_header_was_set(skb)))
		return 0;

	if (unlikely(!skb_hnat_is_hashed(skb)))
		return 0;
		
	if (unlikely(skb->mark == HNAT_EXCEPTION_TAG))
		return 0;

	if (out->netdev_ops->ndo_flow_offload_check) {
		out->netdev_ops->ndo_flow_offload_check(&hw_path);
		out = (IS_GMAC1_MODE) ? hw_path.virt_dev : hw_path.dev;
	}
	
	if (!IS_LAN(out) && !IS_WAN(out) && !IS_EXT(out))
		return 0;

		

	#if defined(CONFIG_MEDIATEK_NETSYS_RX_V2)
	if (!IS_WHNAT(out) && IS_EXT(out) && FROM_WED(skb))
	#endif

 
	trace_printk("[%s] case hit, %x-->%s, reason=%x\n", __func__,
		     skb_hnat_iface(skb), out->name, skb_hnat_reason(skb));

	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];

	switch (skb_hnat_reason(skb)) {
	case HIT_UNBIND_RATE_REACH:
		if (entry_hnat_is_bound(entry))
			break;

		if (fn && !mtk_hnat_accel_type(skb))
			break;

		if (fn && fn(skb, arp_dev, &hw_path))
			break;
		spin_lock(&hnat_priv->entry_lock);
		skb_to_hnat_info(skb, out, entry, &hw_path);
		spin_unlock(&hnat_priv->entry_lock);
		break;
	case HIT_BIND_KEEPALIVE_DUP_OLD_HDR:
		if (fn && !mtk_hnat_accel_type(skb))
			break;

		/* update dscp for qos */
		mtk_hnat_dscp_update(skb, entry);

		/* update mcast timestamp*/
		if (hnat_priv->data->version == MTK_HNAT_V3 &&
		    hnat_priv->data->mcast && entry->bfib1.sta == 1)
			entry->ipv4_hnapt.m_timestamp = foe_timestamp(hnat_priv);

		if (entry_hnat_is_bound(entry)) {
			memset(skb_hnat_info(skb), 0, FOE_INFO_LEN);

			return -1;
		}
		break;
	case HIT_BIND_MULTICAST_TO_CPU:
	case HIT_BIND_MULTICAST_TO_GMAC_CPU:
		/*do not forward to gdma again,if ppe already done it*/
		if (IS_LAN(out) || IS_WAN(out))
			return -1;
		break;
	}

	return 0;
}

static unsigned int
mtk_hnat_ipv6_nf_local_out(void *priv, struct sk_buff *skb,
			   const struct nf_hook_state *state)
{
	struct foe_entry *entry;
	struct ipv6hdr *ip6h;
	struct iphdr _iphdr;
	const struct iphdr *iph;
	struct tcpudphdr _ports;
	const struct tcpudphdr *pptr;
	int udp = 0;

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;

	if (unlikely(!skb_hnat_is_hashed(skb)))
		return NF_ACCEPT;

	ip6h = ipv6_hdr(skb);

	if (ip6h->nexthdr != NEXTHDR_IPIP) {
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);
		return NF_ACCEPT;
	}

	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];
	if (skb_hnat_reason(skb) == HIT_UNBIND_RATE_REACH) {
		if (ip6h->nexthdr == NEXTHDR_IPIP) {
			/* Map-E LAN->WAN: need to record orig info before fn. */
			if (mape_toggle) {
				iph = skb_header_pointer(skb, IPV6_HDR_LEN,
							 sizeof(_iphdr), &_iphdr);
				if (unlikely(!iph))
					return NF_ACCEPT;

				switch (iph->protocol) {
				case IPPROTO_UDP:
					udp = 1;
				case IPPROTO_TCP:
				break;

				default:
					return NF_ACCEPT;
				}

				pptr = skb_header_pointer(skb, IPV6_HDR_LEN + iph->ihl * 4,
							  sizeof(_ports), &_ports);
				if (unlikely(!pptr))
                                        return NF_ACCEPT;

				entry->bfib1.udp = udp;

				/* Map-E LAN->WAN record inner IPv4 header info. */
#if defined(CONFIG_MEDIATEK_NETSYS_V2)
				entry->bfib1.pkt_type = IPV4_MAP_E;
				entry->ipv4_dslite.iblk2.dscp = iph->tos;
				entry->ipv4_dslite.new_sip = ntohl(iph->saddr);
				entry->ipv4_dslite.new_dip = ntohl(iph->daddr);
				entry->ipv4_dslite.new_sport = ntohs(pptr->src);
				entry->ipv4_dslite.new_dport = ntohs(pptr->dst);
#else
				entry->ipv4_hnapt.iblk2.dscp = iph->tos;
				entry->ipv4_hnapt.new_sip = ntohl(iph->saddr);
				entry->ipv4_hnapt.new_dip = ntohl(iph->daddr);
				entry->ipv4_hnapt.new_sport = ntohs(pptr->src);
				entry->ipv4_hnapt.new_dport = ntohs(pptr->dst);
#endif
			} else {
				entry->bfib1.pkt_type = IPV4_DSLITE;
			}
		}
	}
	return NF_ACCEPT;
}

static unsigned int
mtk_hnat_ipv6_nf_post_routing(void *priv, struct sk_buff *skb,
			      const struct nf_hook_state *state)
{
	if (!skb)
		goto drop;

	post_routing_print(skb, state->in, state->out, __func__);

	if (!mtk_hnat_nf_post_routing(skb, state->out, hnat_ipv6_get_nexthop,
				      __func__))
		return NF_ACCEPT;

drop:
	if (skb)
		trace_printk(
			"%s:drop (iif=0x%x, out_dev=%s, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, skb_hnat_iface(skb), state->out->name, HNAT_SKB_CB2(skb)->magic,
			skb_hnat_entry(skb), skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int
mtk_hnat_ipv4_nf_post_routing(void *priv, struct sk_buff *skb,
			      const struct nf_hook_state *state)
{
	if (!skb)
		goto drop;

	post_routing_print(skb, state->in, state->out, __func__);

	if (!mtk_hnat_nf_post_routing(skb, state->out, hnat_ipv4_get_nexthop,
				      __func__))
		return NF_ACCEPT;

drop:
	if (skb)
		trace_printk(
			"%s:drop (iif=0x%x, out_dev=%s, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, skb_hnat_iface(skb), state->out->name, HNAT_SKB_CB2(skb)->magic,
			skb_hnat_entry(skb), skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int
mtk_pong_hqos_handler(void *priv, struct sk_buff *skb,
		      const struct nf_hook_state *state)
{
	struct vlan_ethhdr *veth;

	if (!skb)
		goto drop;

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;

	veth = (struct vlan_ethhdr *)skb_mac_header(skb);

	if (IS_HQOS_MODE && eth_hdr(skb)->h_proto == HQOS_MAGIC_TAG) {
		skb_hnat_entry(skb) = ntohs(veth->h_vlan_TCI) & 0x3fff;
		skb_hnat_reason(skb) = HIT_BIND_FORCE_TO_CPU;
	}

	if (skb_hnat_iface(skb) == FOE_MAGIC_EXT)
		clr_from_extge(skb);

	/* packets from external devices -> xxx ,step 2, learning stage */
	if (do_ext2ge_fast_learn(state->in, skb) && (!qos_toggle ||
	    (qos_toggle && eth_hdr(skb)->h_proto != HQOS_MAGIC_TAG))) {
		if (!do_hnat_ext_to_ge2(skb, __func__))
			return NF_STOLEN;
		goto drop;
	}

	/* packets form ge -> external device */
	if (do_ge2ext_fast(state->in, skb)) {
		if (!do_hnat_ge_to_ext(skb, __func__))
			return NF_STOLEN;
		goto drop;
	}

	return NF_ACCEPT;
drop:
	printk_ratelimited(KERN_WARNING
				"%s:drop (in_dev=%s, iif=0x%x, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
				__func__, state->in->name, skb_hnat_iface(skb),
				HNAT_SKB_CB2(skb)->magic, skb_hnat_entry(skb),
				skb_hnat_sport(skb), skb_hnat_reason(skb),
				skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int
mtk_hnat_br_nf_local_out(void *priv, struct sk_buff *skb,
			 const struct nf_hook_state *state)
{
	if (!skb)
		goto drop;

	post_routing_print(skb, state->in, state->out, __func__);

	if (!mtk_hnat_nf_post_routing(skb, state->out, 0, __func__))
		return NF_ACCEPT;

drop:
	if (skb)
		trace_printk(
			"%s:drop (iif=0x%x, out_dev=%s, CB2=0x%x, ppe_hash=0x%x, sport=0x%x, reason=0x%x, alg=0x%x)\n",
			__func__, skb_hnat_iface(skb), state->out->name, HNAT_SKB_CB2(skb)->magic,
			skb_hnat_entry(skb), skb_hnat_sport(skb), skb_hnat_reason(skb),
			skb_hnat_alg(skb));

	return NF_DROP;
}

static unsigned int
mtk_hnat_ipv4_nf_local_out(void *priv, struct sk_buff *skb,
			   const struct nf_hook_state *state)
{
	struct foe_entry *entry;
	struct iphdr *iph;

	if (!is_magic_tag_valid(skb))
		return NF_ACCEPT;

	if (unlikely(skb_headroom(skb) < FOE_INFO_LEN))
		return NF_ACCEPT;

	if (!skb_hnat_is_hashed(skb))
		return NF_ACCEPT;

	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];

	/* Make the flow from local not be bound. */
	iph = ip_hdr(skb);
	if (iph->protocol == IPPROTO_IPV6) {
		entry->udib1.pkt_type = IPV6_6RD;
		hnat_set_head_frags(state, skb, 0, hnat_set_alg);
	} else {
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);
	}

	return NF_ACCEPT;
}

static unsigned int mtk_hnat_br_nf_forward(void *priv,
					   struct sk_buff *skb,
					   const struct nf_hook_state *state)
{
	if ((hnat_priv->data->version == MTK_HNAT_V2) &&
	    unlikely(IS_EXT(state->in) && IS_EXT(state->out)))
		hnat_set_head_frags(state, skb, 1, hnat_set_alg);

	return NF_ACCEPT;
}

/* mtk_hnat_tproxy_protection_v4 - fired at NF_IP_PRI_MANGLE+1 (-149),
 * AFTER iptables mangle PREROUTING (-150) where xt_TPROXY sets
 * skb->mark |= 0x8000 (SSR Plus tproxy-mark 0x8000/0x8000).
 *
 * Mark bit 15 (0x8000) is chosen to avoid collisions with:
 *   - eqos QoS marks  : 2-31     (bits 0-4)
 *   - DSCP/QID range  : 0-63     (bits 0-5)
 *   - mwan3 interface : 1-255    (bits 0-7)
 *
 * Goal: prevent HNAT from stably binding UDP flows that SSR's tproxy
 * has intercepted, so hardware offload never bypasses tproxy.
 * Non-SSR UDP flows (mark & 0x8000 == 0) are fully hardware-accelerated.
 */
static unsigned int mtk_hnat_tproxy_protection_v4(
	void *priv, struct sk_buff *skb,
	const struct nf_hook_state *state)
{
	struct foe_entry *entry;
	struct iphdr *iph;

	/* Only act on packets that HNAT has already tagged */
	if (!is_magic_tag_valid(skb) || !skb_hnat_is_hashed(skb)) {
		pr_debug("[HNAT-TPX-1] skip: magic_valid=%d hashed=%d\n",
			 is_magic_tag_valid(skb), skb_hnat_is_hashed(skb));
		return NF_ACCEPT;
	}

	/* Protect both TCP and UDP tproxy flows.
	 *
	 * Original code only guarded UDP. TCP TPROXY flows (e.g. VMESS+WS+TLS
	 * intercepted via xt_TPROXY) carry the same mark bit 15 (0x8000) and
	 * are equally at risk of HNAT binding their FOE entry, which would
	 * cause hardware to bypass Xray and deliver raw encrypted tunnel data
	 * directly to LAN clients.  Extend the guard to all IP protocols that
	 * carry mark bit 15; non-TCP/UDP protocols will naturally never be
	 * tproxy-marked so there is no false-positive risk.
	 */
	iph = ip_hdr(skb);
	if (iph->protocol != IPPROTO_UDP && iph->protocol != IPPROTO_TCP) {
		pr_debug("[HNAT-TPX-2] skip: proto=%u (not TCP/UDP)\n",
			 iph->protocol);
		return NF_ACCEPT;
	}

	if (!(skb->mark & 0x8000)) {
		pr_debug("[HNAT-TPX-3] skip: mark=0x%x (bit15 not set, not tproxy)\n",
			 skb->mark);
		return NF_ACCEPT;
	}

	/* Zero the FOE entry ONLY if it is in BIND state (B-017 root-cause fix).
	 *
	 * Why only BIND:
	 *   TPROXY flows are delivered to LOCAL_IN, bypassing FORWARD/POSTROUTING.
	 *   HNAT can only BIND a flow it observes on FORWARD/POSTROUTING, so a
	 *   TPROXY flow's own FOE entry is ALWAYS UNBIND — it can never be BIND
	 *   through the TPROXY path.
	 *
	 *   The ONLY case where we MUST zero is when HNAT hardware has already
	 *   BIND-accelerated a 5-tuple that was later re-routed through TPROXY
	 *   (ASIC "sample" path: hardware sends a BIND-state packet to CPU for
	 *   re-validation).  Zeroing that BIND entry evicts it from hardware so
	 *   subsequent packets are not accelerated past the proxy.
	 *
	 * Why UNBIND must NOT be zeroed (B-017):
	 *   FOE slots are assigned by a hash of the 5-tuple.  A TPROXY SYN and
	 *   an unrelated direct-connect (non-proxy) TCP connection can hash to the
	 *   SAME FOE slot.  If we zero the UNBIND slot for the TPROXY packet, we
	 *   accidentally evict the direct-connect connection's UNBIND entry before
	 *   it can accumulate enough packets to reach HIT_UNBIND_RATE_REACH and
	 *   transition to BIND.  The direct-connect flow is forced to CPU path
	 *   indefinitely → intermittent latency spikes whenever such a hash
	 *   collision occurs ("偶发延迟").
	 *
	 *   For UNBIND entries: the FOE slot holds no ASIC-visible state, so
	 *   there is nothing to evict.  We can safely return NF_ACCEPT.
	 *
	 * hnat_cache_ebl(1) is only needed for BIND→INVALID transitions.
	 */
	entry = &hnat_priv->foe_table_cpu[skb_hnat_ppe(skb)][skb_hnat_entry(skb)];
	{
		u8 foe_state = entry_hnat_state(entry);
		pr_debug("[HNAT-TPX-4-B017] TPROXY hit: src=%pI4 dst=%pI4 proto=%u foe_idx=%u state=%u mark=0x%x\n",
			 &iph->saddr, &iph->daddr, iph->protocol,
			 skb_hnat_entry(skb), foe_state, skb->mark);

		if (foe_state != BIND) {
			/* UNBIND/INVALID: nothing to evict, TPROXY flow cannot be
			 * hardware-accelerated anyway.  Return without touching the slot
			 * so other connections sharing this hash are not disrupted. */
			pr_debug("[HNAT-TPX-5-B017] UNBIND/INVALID: skip memset (no ASIC state to evict)\n");
			goto done;
		}

		/* BIND state: ASIC has this flow accelerated — zero it out so the
		 * hardware stops forwarding packets that should go through TPROXY. */
		memset(entry, 0, sizeof(struct foe_entry));
		hnat_cache_ebl(1);
		pr_debug("[HNAT-TPX-5-B017] BIND→INVALID: evicted + cache flushed\n");
	}
done:

	/* B-017: Remove ct->mark |= 0x8000 write.
	 *
	 * Reason 1 (dead code): The only consumer of this write was
	 * mtk_hnat_tproxy_connmark_check_v4(), which was deleted in commit
	 * 8fb160ffb5.  No code in this driver reads ct->mark for the 0x8000 bit
	 * anymore.  Keeping the write is pure overhead.
	 *
	 * Reason 2 (potential CONNMARK side-effect): eqos/loadbalance install:
	 *   POSTROUTING -m conntrack --ctstate NEW -j CONNMARK --save-mark
	 * This saves skb->mark into ct->mark for every NEW packet.  For TPROXY
	 * flows the NEW packet is delivered LOCAL_IN (not POSTROUTING), so
	 * save-mark does not fire and ct->mark retains the 0x8000 we write here.
	 * Subsequently, if loadbalance is active without the tproxy_mark_guard
	 * (init.d/eqos L78 restore-mark path has no ! --mark 0x8000/0x8000),
	 * 0x8000 can leak into skb->mark of ESTABLISHED packets on some code
	 * paths, causing tproxy_protection_v4 to fire again per packet and
	 * repeatedly memset(FOE, 0), preventing HNAT from ever binding those
	 * flows (intermittent latency, B-017).
	 *
	 * tproxy_protection_v4 already gates on skb->mark & 0x8000 set by
	 * iptables TPROXY at MANGLE(-150) — no ct->mark persistence needed.
	 */
	pr_debug("[HNAT-TPX-B017-01] done (ct->mark write removed: dead code + CONNMARK leak prevention)\n");
	return NF_ACCEPT;
}

static struct nf_hook_ops mtk_hnat_nf_ops[] __read_mostly = {
	{
		.hook = mtk_hnat_nf_conntrack,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE-1,
	},
	{
		.hook = mtk_hnat_nf_conntrack,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE-1,
	},
	{
		.hook = mtk_hnat_ipv4_nf_pre_routing,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_FIRST + 1,
	},
	{
		.hook = mtk_hnat_ipv6_nf_pre_routing,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_FIRST + 1,
	},
	{
		.hook = mtk_hnat_ipv6_nf_post_routing,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_POST_ROUTING,
		.priority = NF_IP_PRI_LAST,
	},
	{
		.hook = mtk_hnat_ipv6_nf_local_out,
		.pf = NFPROTO_IPV6,
		.hooknum = NF_INET_LOCAL_OUT,
		.priority = NF_IP_PRI_LAST,
	},
	{
		.hook = mtk_hnat_ipv4_nf_post_routing,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_POST_ROUTING,
		.priority = NF_IP_PRI_LAST,
	},
	{
		.hook = mtk_hnat_ipv4_nf_local_out,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_LOCAL_OUT,
		.priority = NF_IP_PRI_LAST,
	},
	{
		/* Fire AFTER iptables mangle (-150) so tproxy mark is set */
		.hook = mtk_hnat_tproxy_protection_v4,
		.pf = NFPROTO_IPV4,
		.hooknum = NF_INET_PRE_ROUTING,
		.priority = NF_IP_PRI_MANGLE + 1,
	},
	{
		.hook = mtk_hnat_br_nf_local_in,
		.pf = NFPROTO_BRIDGE,
		.hooknum = NF_BR_LOCAL_IN,
		.priority = NF_BR_PRI_FIRST,
	},
	{
		.hook = mtk_hnat_br_nf_local_out,
		.pf = NFPROTO_BRIDGE,
		.hooknum = NF_BR_LOCAL_OUT,
		.priority = NF_BR_PRI_LAST - 1,
	},
	{
		.hook = mtk_pong_hqos_handler,
		.pf = NFPROTO_BRIDGE,
		.hooknum = NF_BR_PRE_ROUTING,
		.priority = NF_BR_PRI_FIRST + 1,
	},
};

int hnat_register_nf_hooks(void)
{
	return nf_register_net_hooks(&init_net, mtk_hnat_nf_ops, ARRAY_SIZE(mtk_hnat_nf_ops));
}

void hnat_unregister_nf_hooks(void)
{
	nf_unregister_net_hooks(&init_net, mtk_hnat_nf_ops, ARRAY_SIZE(mtk_hnat_nf_ops));
}

int whnat_adjust_nf_hooks(void)
{
	struct nf_hook_ops *hook = mtk_hnat_nf_ops;
	unsigned int n = ARRAY_SIZE(mtk_hnat_nf_ops);

	while (n-- > 0) {
		if (hook[n].hook == mtk_hnat_br_nf_local_in) {
			hook[n].hooknum = NF_BR_PRE_ROUTING;
			hook[n].priority = NF_BR_PRI_FIRST + 1;
		} else if (hook[n].hook == mtk_hnat_br_nf_local_out) {
			hook[n].hooknum = NF_BR_POST_ROUTING;
		} else if (hook[n].hook == mtk_pong_hqos_handler) {
			hook[n].hook = mtk_hnat_br_nf_forward;
			hook[n].hooknum = NF_BR_FORWARD;
			hook[n].priority = NF_BR_PRI_LAST - 1;
		}
	}

	return 0;
}

int mtk_hqos_ptype_cb(struct sk_buff *skb, struct net_device *dev,
		      struct packet_type *pt, struct net_device *unused)
{
	struct vlan_ethhdr *veth = (struct vlan_ethhdr *)skb_mac_header(skb);

	skb_hnat_entry(skb) = ntohs(veth->h_vlan_TCI) & 0x3fff;
	skb_hnat_reason(skb) = HIT_BIND_FORCE_TO_CPU;

	do_hnat_ge_to_ext(skb, __func__);

	return 0;
}
