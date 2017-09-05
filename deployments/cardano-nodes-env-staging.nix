{ globals, ... }: with (import ./../lib.nix);
let nodeMap = globals.nodeMap; in


(flip mapAttrs nodeMap (name: import ./../modules/cardano-staging.nix))
//
{
  resources = {
    elasticIPs = nodesElasticIPs nodeMap;
    datadogMonitors = (with (import ./../modules/datadog-monitors.nix); {
      cpu = mkMonitor (cpu_monitor // {
        message = pagerDutyPolicy.nonCritical;
        query = config: "avg(last_5m):avg:system.load.norm.1{env:${config.deployment.name}} by {host} > 0.99";
        monitorOptions.thresholds = {
          warning = "0.98";
          critical = "0.99";
        };
      });

      cardano_node_simple_process = mkMonitor (cardano_node_simple_process_monitor // {
        message = pagerDutyPolicy.nonCritical;
        monitorOptions.thresholds = {
          warning = 3;
          critical = 4;
          ok = 1;
        };
      });
    });
  };
}
