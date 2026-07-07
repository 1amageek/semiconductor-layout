enum RoutingResultContracts {
    static func resultWithoutViaDefinition(for nets: [RoutingNet]) -> RoutingResult {
        var routes: [RoutedNet] = []
        var unroutedNets: [String] = []

        for net in nets {
            if net.pins.isEmpty {
                unroutedNets.append(net.name)
            } else if net.isPower {
                unroutedNets.append(net.name)
            } else if net.pins.count == 1 {
                routes.append(RoutedNet(netID: net.id))
            } else {
                unroutedNets.append(net.name)
            }
        }

        return RoutingResult(routes: routes, unroutedNets: unroutedNets)
    }
}
