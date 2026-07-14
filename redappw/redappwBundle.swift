//
//  redappwBundle.swift
//  redappw
//
//  Created by john val on 10/10/25.
//

import WidgetKit
import SwiftUI

@main
struct redappwBundle: WidgetBundle {
    var body: some Widget {
        redappw()
        redappwControl()
        BatchSummaryLiveActivityWidget()
    }
}
