#
# Copyright 2014, SUSE
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Functions to help recipes register resources in the Pacemaker cluster
# via the LWRPs provided by the pacemaker cookbook.
#
# Even though the haproxy frontend only runs on one node at a time, we
# need to ensure that all nodes have haproxy.cfg correctly configured
# ahead of time, in case the frontend needs to be failed over.
module CrowbarPacemakerHelper
  def self.cluster_enabled?(node)
    return !(node[:pacemaker][:config][:environment] rescue nil).nil?
  end

  def self.is_cluster_founder?(node)
    if cluster_enabled?(node)
      node[:pacemaker][:founder]
    else
      false
    end
  end

  # Returns the name of the cluster containing the given node, or nil
  # if the node is not in a cluster.  The name is determined by the
  # name of the pacemaker proposal corresponding to that cluster
  # (minus the "pacemaker-config-" prefix which is visible at the Chef
  # level).
  #
  # This call signature only makes sense because it is not possible
  # for a node to be in multiple clusters.
  def self.cluster_name(node)
    if cluster_enabled?(node)
      node[:pacemaker][:config][:environment].gsub("pacemaker-config-", "")
    else
      nil
    end
  end

  # Floating virtual IPs are used for the haproxy frontend endpoints,
  # and these have corresponding virtual hostnames.  This helper
  # constructs the non-qualified host prefix part of the virtual
  # hostname.
  def self.cluster_vhostname(node)
    if cluster_enabled?(node)
      # We know that the proposal name cannot contain a dash, and we know that
      # a hostname cannot contain an underscore, so we're lucky and we can
      # substitute one with the other
      # Similar code is in the barclamp side:
      # allocate_virtual_ips_for_cluster_in_networks
      "cluster-#{cluster_name(node)}".gsub("_", "-")
    else
      nil
    end
  end

  # The virtual admin name for the cluster is a name picked by the operator as
  # an alias for the generated virtual FQDN. It might be wanted if the operator
  # does not want to expose "cluster-foo.domain" to end users.
  # This returns nil if there is no defined virtual admin name or if node is
  # not member of a cluster.
  def self.cluster_haproxy_vadmin_name(node)
    if cluster_enabled?(node)
      vadmin_name = node[:pacemaker][:haproxy][:admin_name]
      if vadmin_name.nil? || vadmin_name.empty?
        nil
      else
        vadmin_name
      end
    else
      nil
    end
  end

  # The virtual public name for the cluster is a name picked by the operator as
  # an alias for the generated virtual FQDN. It might be wanted if the operator
  # does not want to expose "cluster-foo.domain" to end users.
  # This returns nil if there is no defined virtual public name or if node is
  # not member of a cluster.
  def self.cluster_haproxy_vpublic_name(node)
    if cluster_enabled?(node)
      vpublic_name = node[:pacemaker][:haproxy][:public_name]
      if vpublic_name.nil? || vpublic_name.empty?
        nil
      else
        vpublic_name
      end
    else
      nil
    end
  end

  # Performs a Chef search and returns an Array of Node objects for
  # all nodes in the same cluster as the given node, or an empty array
  # if the node isn't in a cluster.  Can optionally filter by role.
  #
  # This call signature only makes sense because it is not possible
  # for a node to be in multiple clusters.
  def self.cluster_nodes(node, role = "*")
    if cluster_enabled?(node)
      server_nodes = []
      # Sometimes, chef-server is a little bit outdated and doesn't have the
      # latest information, including the fact that the current node is
      # actually part of the cluster; we also want to make sure that we include
      # the latest bits with latest attributes for this node, so we always
      # manually add it, instead of relying on the search for this one.
      Chef::Search::Query.new.search(:node, "roles:#{role || "*"} AND pacemaker_config_environment:#{node[:pacemaker][:config][:environment]}") do |o|
        server_nodes << o if o.name != node.name
      end
      server_nodes << node if (role.nil? || role == "*" || node.roles.include?(role))
      server_nodes
    else
      []
    end
  end

  # Returns the founder of the cluster the current node belongs to, or nil if
  # the current node is not part of a cluster
  def self.cluster_founder(node)
    if cluster_enabled?(node)
      if is_cluster_founder? node
        node
      else
        founders = []
        Chef::Search::Query.new.search(:node, "pacemaker_founder:true AND pacemaker_config_environment:#{node[:pacemaker][:config][:environment]}") do |o|
          founders << o if o.name != node.name
        end
        founders << node if (node[:pacemaker][:founder] rescue false) == true
        raise "No cluster founders found!" if founders.empty?
        raise "Multiple cluster founders found!" if founders.length > 1
        founders.first
      end
    else
      nil
    end
  end

  # Returns an Array with two elements:
  #
  # 1. An Array of Hashes representing haproxy backend servers,
  #    where each Hash looks something like:
  #
  #      {
  #        'name' => 'd52-54-00-b5-4c-c6.crowbar.site',
  #        'address' => '192.168.124.81',
  #        'port' => 0,
  #      }
  #
  #    This Array will eventually be passed to the
  #    haproxy_loadbalancer LWRP as the servers parameter.
  #
  # 2. A Hash mapping the hostnames of the haproxy backend servers
  #    to their Chef Node objects.  This will be used to obtain
  #    additional data from the Node.
  def self.haproxy_servers(node, role = "*")
    haproxy_servers = []
    haproxy_servers_nodes = {}

    server_nodes = cluster_nodes(node, role)

    server_nodes.each do |server_node|
      haproxy_server = {}
      haproxy_server['name'] = server_node[:hostname]
      haproxy_server['address'] = server_node[:ipaddress]
      haproxy_server['port'] = 0
      haproxy_servers << haproxy_server
      haproxy_servers_nodes[server_node[:hostname]] = server_node
    end

    [haproxy_servers, haproxy_servers_nodes]
  end

  # Each node uses Chef search via #cluster_nodes in order to
  # determine the list of haproxy backend servers which need to be
  # included in haproxy.cfg.  In order to minimise the number of Chef
  # searches and the consequent building of data structures, we
  # memoize the results in this cache.  It is keyed by (node, role)
  # tuple and the values are the 2-element Arrays returned by
  # #haproxy_servers.  (Technically it should be keyed by (cluster,
  # role), since the results should be the same for any node within
  # the cluster, but since the cache is not shared and has to be
  # constructed per node, it should not make any difference, because
  # calls to #haproxy_servers_for_service and #haproxy_servers on a
  # single node should never span multiple clusters.)
  @@haproxy_servers_cache = {}

  # Returns an Array of servers that can be passed as the servers
  # parameter to the haproxy_loadbalancer LWRP.  It assumes that all
  # the servers that will be load-balanced are listening on the admin
  # network.
  #
  # Arguments:
  #   - node
  #       the current Chef node object (facilitates access to
  #       relevant attributes)
  #   - name
  #       used in conjunction with 'ports_key' parameter to
  #       obtain the correct port to use for each server, which is stored
  #       in the server_node[name][:ha][:ports][ports_key] attribute
  #   - role
  #       the name of the Chef role managing this service (used
  #       to ensure the results are memoized per role)
  #   - ports_key
  #       used in conjunction with 'name' parameter - see above
  #
  # Concrete example:
  #
  #   CrowbarPacemakerHelper.haproxy_servers_for_service(node, "glance", "glance-server", "api")
  #
  # This would:
  #   - look for all nodes in the cluster with the glance-server role
  #   - create a list of servers to be used with the haproxy_loadbalancer
  #     LWRP, with each found node being an element of the list, with:
  #     - the admin IP of the node used as the address field
  #     - the glance.ha.ports.api (where glance and api come from the name
  #       and ports_key parameters) attribute of the node used as the port
  #       field
  def self.haproxy_servers_for_service(node, name, role, ports_key)
    # Fetch configured HA proxy servers for a given service
    cache_key = "#{node}-#{role}"

    servers, server_nodes = @@haproxy_servers_cache.fetch(cache_key) do
      @@haproxy_servers_cache[cache_key] = haproxy_servers(node, role)
    end

    # Clone each server Hash because we're going to change each of
    # them, and we don't want to change the cache which is shared
    # between all callers.  This is because different callers will
    # use different values for the 'name' parameter, which can result
    # in different port values.
    servers = servers.map { |s| s.clone }

    # Look up and store where they are listening
    servers.each do |server|
      server_node = server_nodes[server['name']]

      server['address'] = Chef::Recipe::Barclamp::Inventory.get_network_by_type(server_node, "admin").address
      server['port']    = server_node[name.to_sym][:ha][:ports][ports_key.to_sym]
    end

    servers
  end
end
