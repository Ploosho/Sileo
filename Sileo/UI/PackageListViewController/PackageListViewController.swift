//
//  PackageListViewController.swift
//  Sileo
//
//  Created by CoolStar on 8/14/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import Evander
import os

class PackageListViewController: SileoViewController, UIGestureRecognizerDelegate {
    @IBOutlet final var collectionView: UICollectionView?
    @IBOutlet final var downloadsButton: UIBarButtonItem?
    
    @IBInspectable final var showSearchField: Bool = false
    @IBInspectable final var showUpdates: Bool = false
    @IBInspectable final var showWishlist: Bool = false
    @IBInspectable final public var loadProvisional: Bool = false
     
    @IBInspectable final public var packagesLoadIdentifier: String = ""
    final public var repoContext: Repo?
    final private var showProvisional: Bool = false
    
    final private var packages: [Package] = []
    final private var availableUpdates: [Package] = []
    final private var ignoredUpdates: [Package] = []
    final private var searchCache: [String: [Package]] = [:]
    final private var provisionalPackages: [ProvisionalPackage] = []
    final private var cachedInstalled: [Package]?
    
    private var displaySettings = false
    
    private let searchingQueue = DispatchQueue(label: "Sileo.PackageList.Searching", qos: .userInitiated)
    private var updatingCount = 0 {
        didSet {
            if updatingCount < 0 {
                updatingCount = 0
            }
        }
    }
    private var canisterHeartbeat: Timer?
    
    @IBInspectable var localizableTitle: String = ""
    
    var searchController: UISearchController?
    
    @objc func updateSileoColors() {
        self.statusBarStyle = .default
        if let textField = searchController?.searchBar.value(forKey: "searchField") as? UITextField {
            textField.textColor = .sileoLabel
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        updateSileoColors()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateSileoColors()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.navigationController?.navigationBar._hidesShadow = true
        
        guard #available(iOS 13, *) else {
            if showSearchField {
                self.navigationItem.hidesSearchBarWhenScrolling = false
            }
            return
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationController?.navigationBar._hidesShadow = false
        
        guard let visibleCells = collectionView?.visibleCells else {
            return
        }
        for cell in visibleCells {
            if let packageCell = cell as? PackageCollectionViewCell {
                packageCell.hideSwipe(animated: false)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        if loadProvisional {
            showProvisional = UserDefaults.standard.optionalBool("ShowProvisional", fallback: true)
            _ = NotificationCenter.default.addObserver(forName: Notification.Name("ShowProvisional"), object: nil, queue: nil) { _ in
                self.showProvisional = UserDefaults.standard.optionalBool("ShowProvisional", fallback: true)
                self.collectionView?.reloadData()
            }
        }
        
        if showUpdates {
            _ = NotificationCenter.default.addObserver(forName: Notification.Name("ShowIgnoredUpdates"), object: nil, queue: nil) { _ in
                self.reloadUpdates()
            }
        }

        if showWishlist {
            let exportBtn = UIBarButtonItem(title: String(localizationKey: "Export"), style: .plain, target: self, action: #selector(self.exportButtonClicked(_:)))
            self.navigationItem.leftBarButtonItem = exportBtn
            
            let wishlistBtn = UIBarButtonItem(title: String(localizationKey: "Wishlist"), style: .plain, target: self, action: #selector(self.showWishlist(_:)))
            self.navigationItem.rightBarButtonItem = wishlistBtn
        }
        
        if packagesLoadIdentifier.contains("--wishlist") {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData), name: WishListManager.changeNotification, object: nil)
        }
        
        if !localizableTitle.isEmpty {
            self.title = String(localizationKey: localizableTitle)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData),
                                               name: PackageListManager.reloadNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadStates(_:)), name: PackageListManager.stateChange, object: nil)
        if self.showUpdates {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadUpdates),
                                                   name: PackageListManager.prefsNotification,
                                                   object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadUpdates), name: PackageListManager.installChange, object: nil)
        }
        if loadProvisional {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData),
                                                   name: CanisterResolver.refreshList,
                                                   object: nil)
        }
        
        // A value of exactly 17.0 (the default) causes the text to auto-shrink
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).defaultTextAttributes = [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17.01)
        ]
        
        searchController = UISearchController(searchResultsController: nil)
        searchController?.searchBar.placeholder = String(localizationKey: "Package_Search.Placeholder")
        if #available(iOS 13, *) {
            searchController?.searchBar.searchTextField.semanticContentAttribute = LanguageHelper.shared.isRtl ? .forceRightToLeft : .forceLeftToRight
        } else {
            let textfieldOfSearchBar = searchController?.searchBar.value(forKey: "searchField") as? UITextField
            textfieldOfSearchBar?.semanticContentAttribute = LanguageHelper.shared.isRtl ? .forceRightToLeft : .forceLeftToRight
        }
        searchController?.searchBar.delegate = self
        searchController?.searchResultsUpdater = self
        searchController?.obscuresBackgroundDuringPresentation = false
        searchController?.hidesNavigationBarDuringPresentation = true
        
        self.navigationController?.navigationBar.superview?.tag = WHITE_BLUR_TAG
        
        self.navigationItem.hidesSearchBarWhenScrolling = false
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true
        
        var sbTextField: UITextField?
        if #available(iOS 13, *) {
            sbTextField = searchController?.searchBar.searchTextField
        } else {
            sbTextField = searchController?.searchBar.value(forKey: "_searchField") as? UITextField
        }
        sbTextField?.font = UIFont.systemFont(ofSize: 13)
        
        let tapRecognizer = UITapGestureRecognizer(target: searchController?.searchBar, action: #selector(UISearchBar.resignFirstResponder))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        
        if let collectionView = collectionView {
            collectionView.addGestureRecognizer(tapRecognizer)
            collectionView.register(UINib(nibName: "PackageCollectionViewCell", bundle: nil),
                                    forCellWithReuseIdentifier: "PackageListViewCellIdentifier")
        
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            flowLayout?.sectionHeadersPinToVisibleBounds = true
        
            collectionView.register(UINib(nibName: "PackageListHeader", bundle: nil),
                                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                    withReuseIdentifier: "PackageListHeader")
            collectionView.register(UINib(nibName: "PackageListHeaderBlank", bundle: nil),
                                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                    withReuseIdentifier: "PackageListHeaderBlank")
        
            self.registerForPreviewing(with: self, sourceView: collectionView)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let packageMan = PackageListManager.shared
            
            if !self.showSearchField {
                let pkgs = packageMan.packageList(identifier: self.packagesLoadIdentifier, sortPackages: true, repoContext: self.repoContext)
                self.packages = pkgs
                self.searchCache[""] = pkgs
                if let controller = self.searchController {
                    DispatchQueue.main.async { self.updateSearchResults(for: controller) }
                }
            }
            if self.showUpdates {
                let updates = packageMan.availableUpdates()
                self.availableUpdates = updates.filter({ $0.1?.wantInfo != .hold }).map({ $0.0 })
                if UserDefaults.standard.optionalBool("ShowIgnoredUpdates", fallback: true) {
                    self.ignoredUpdates = updates.filter({ $0.1?.wantInfo == .hold }).map({ $0.0 })
                }
            }
            
            DispatchQueue.main.async {
                if !self.availableUpdates.isEmpty {
                    self.navigationController?.tabBarItem.badgeValue = String(format: "%ld", self.availableUpdates.count)
                } else {
                    self.navigationController?.tabBarItem.badgeValue = nil
                }
                
                if let searchController = self.searchController {
                    self.updateSearchResults(for: searchController)
                }
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        searchController?.searchBar.isFirstResponder ?? false
    }
    
    func controller(package: Package) -> PackageActions {
        NativePackageViewController.viewController(for: package)
    }
    
    func controller(indexPath: IndexPath) -> PackageActions? {
        switch findWhatFuckingSectionThisIs(indexPath.section) {
        case .canister:
            let pro = provisionalPackages[indexPath.row]
            guard let package = CanisterResolver.package(pro) else { return nil }
            return controller(package: package)
        case .ignoredUpdates: return controller(package: ignoredUpdates[indexPath.row])
        case .packages, .reallyBoringList: return controller(package: packages[indexPath.row])
        case .updates: return controller(package: availableUpdates[indexPath.row])
        }
    }

    @objc func reloadData() {
        self.searchCache = [:]
        self.cachedInstalled = nil
        if showUpdates {
            self.reloadUpdates()
        } else {
            if let searchController = self.searchController {
                self.updateSearchResults(for: searchController)
            }
        }
    }
    
    @objc func reloadStates(_ notification: Notification) {
        let wasInstall = notification.object as? Bool ?? false
        Thread.mainBlock { [weak self] in
            guard let self = self else { return }
            let packageCells = self.collectionView?.visibleCells.compactMap { $0 as? PackageCollectionViewCell } ?? []
            if wasInstall {
                packageCells.forEach { $0.stateBadgeView?.isHidden = true }
            } else {
                packageCells.forEach { $0.refreshState() }
            }
        }
    }
        
    @objc func reloadUpdates() {
        if showUpdates {
            DispatchQueue.global(qos: .userInteractive).async {
                let updates = PackageListManager.shared.availableUpdates()
                self.availableUpdates = updates.filter({ $0.1?.wantInfo != .hold }).map({ $0.0 })
                if UserDefaults.standard.optionalBool("ShowIgnoredUpdates", fallback: true) {
                    self.ignoredUpdates = updates.filter({ $0.1?.wantInfo == .hold }).map({ $0.0 })
                } else {
                    self.ignoredUpdates.removeAll()
                }
                DispatchQueue.main.async {
                    if !self.availableUpdates.isEmpty {
                        self.navigationController?.tabBarItem.badgeValue = String(format: "%ld", self.availableUpdates.count)
                        UIApplication.shared.applicationIconBadgeNumber = self.availableUpdates.count
                    } else {
                        self.navigationController?.tabBarItem.badgeValue = nil
                        UIApplication.shared.applicationIconBadgeNumber = 0
                    }
                    self.cachedInstalled = nil
                    self.searchCache = [:]
                    if let searchController = self.searchController {
                        self.updateSearchResults(for: searchController)
                    }
                }
            }
        }
    }
    
    @objc func exportButtonClicked(_ button: UIButton?) {
        let alert = UIAlertController(title: String(localizationKey: "Export"), message: String(localizationKey: "Export_Packages"), preferredStyle: .alert)
        
        let defaultAction = UIAlertAction(title: String(localizationKey: "Export_Yes"), style: .default, handler: { _ in
            let pkgs = self.getPackages()
            let activityVC = UIActivityViewController(activityItems: [pkgs], applicationActivities: nil)

            activityVC.popoverPresentationController?.sourceView = self.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)

            self.present(activityVC, animated: true, completion: nil)
        })
        
        alert.addAction(defaultAction)
        
        let cancelAction = UIAlertAction(title: String(localizationKey: "Export_No"), style: .cancel, handler: { _ in
        })
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true)
    }
    
    func getPackages() -> String {
        var bodyFromArray = ""
        let packages = self.packages
        for package in packages {
            guard let packageName = package.name else {
                continue
            }
            let packageVersion = package.version
            
            bodyFromArray += "\(packageName): \(packageVersion)\n"
        }
        
        if let subRange = Range<String.Index>(NSRange(location: bodyFromArray.count - 1, length: 1), in: bodyFromArray) {
            bodyFromArray.removeSubrange(subRange)
        }
        
        return bodyFromArray
    }
    
    enum SortMode {
        case name
        case installdate
        case size
        
        init(from string: String?) {
            switch string {
            case "installdate": self = .installdate
            case "size": self = .size
            default: self = .name
            }
        }
        
        init() {
            self = .init(from: UserDefaults.standard.string(forKey: "InstallSortType"))
        }
    }
    
    @objc func showWishlist(_ sender: Any?) {
        let wishlistController = PackageListViewController(nibName: "PackageListViewController", bundle: nil)
        wishlistController.title = String(localizationKey: "Wishlist")
        wishlistController.packagesLoadIdentifier = "--wishlist"
        self.navigationController?.pushViewController(wishlistController, animated: true)
    }
    
    private func hapticResponse() {
        if #available(iOS 13, *) {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.impactOccurred()
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }
    
    var isEnabled = true
    @objc func upgradeAllClicked(_ sender: Any?) {
        guard isEnabled else { return }
        isEnabled = false
        hapticResponse()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            PackageListManager.shared.upgradeAll {
                self?.isEnabled = true
            }
        }
    }
    
    @objc func sortPopup(sender: UIView?) {
        let alert = UIAlertController(title: String(localizationKey: "Sort_By"), message: nil, preferredStyle: .actionSheet)
        alert.modalPresentationStyle = .popover
        alert.popoverPresentationController?.sourceView = sender
        
        let nameAction = UIAlertAction(title: String(localizationKey: "Sort_Name"), style: .default, handler: { _ in
            UserDefaults.standard.set("name", forKey: "InstallSortType")
            if let searchController = self.searchController {
                self.updateSearchResults(for: searchController)
            }
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(nameAction)
        
        let dateAction = UIAlertAction(title: String(localizationKey: "Sort_Date"), style: .default, handler: { _ in
            UserDefaults.standard.set("installdate", forKey: "InstallSortType")
            if let searchController = self.searchController {
                self.updateSearchResults(for: searchController)
            }
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(dateAction)
        
        let sizeAction = UIAlertAction(title: String(localizationKey: "Sort_Install_Size"), style: .default, handler: { _ in
            UserDefaults.standard.set("size", forKey: "InstallSortType")
            if let searchController = self.searchController {
                self.updateSearchResults(for: searchController)
            }
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(sizeAction)
        
        let cancelAction = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true, completion: nil)
    }
}

extension PackageListViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        var count = 0
        if !packages.isEmpty { count += 1 }
        if showUpdates {
            if !availableUpdates.isEmpty { count += 1 }
            if !ignoredUpdates.isEmpty { count += 1 }
        }
        if showProvisional && loadProvisional {
            if !provisionalPackages.isEmpty { count += 1 }
        }
        return count
    }
    
    private func findWhatFuckingSectionThisIs(_ section: Int) -> PackageListSection {
        if showUpdates {
            if !availableUpdates.isEmpty && section == 0 {
                return .updates
            } else if availableUpdates.isEmpty && !ignoredUpdates.isEmpty && section == 0 {
                return .ignoredUpdates
            } else if section == 1 && !availableUpdates.isEmpty && !ignoredUpdates.isEmpty {
                return .ignoredUpdates
            }
            return .packages
        }
        if loadProvisional {
            if !showProvisional { return .reallyBoringList }
            if section == 1 {
                return .canister
            } else if section == 0 && !packages.isEmpty {
                return .packages
            } else if section == 0 && packages.isEmpty {
                return .canister
            }
        }
        return .reallyBoringList
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch findWhatFuckingSectionThisIs(section) {
        case .canister: return provisionalPackages.count
        case .ignoredUpdates: return ignoredUpdates.count
        case .packages, .reallyBoringList: return packages.count
        case .updates: return availableUpdates.count
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cellIdentifier = "PackageListViewCellIdentifier"
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellIdentifier, for: indexPath) as? PackageCollectionViewCell else {
            fatalError("This is what we call a pro gamer move, where we fatalError because of something horrendous")
        }
        switch findWhatFuckingSectionThisIs(indexPath.section) {
        case .canister: cell.provisionalTarget = provisionalPackages[safe: indexPath.row]; cell.targetPackage = nil
        case .ignoredUpdates: cell.targetPackage = ignoredUpdates[safe: indexPath.row]; cell.provisionalTarget = nil
        case .packages, .reallyBoringList: cell.targetPackage = packages[safe: indexPath.row]; cell.provisionalTarget = nil
        case .updates: cell.targetPackage = availableUpdates[safe: indexPath.row]; cell.provisionalTarget = nil
        }
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let section = findWhatFuckingSectionThisIs(indexPath.section)
        if section == .reallyBoringList {
            if kind == UICollectionView.elementKindSectionHeader {
                let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                                 withReuseIdentifier: "PackageListHeaderBlank",
                                                                                 for: indexPath)
                return headerView
            }
        }
        guard let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                               withReuseIdentifier: "PackageListHeader",
                                                                               for: indexPath) as? PackageListHeader
        else {
            return UICollectionReusableView()
        }
        switch findWhatFuckingSectionThisIs(indexPath.section) {
        case .canister:
            headerView.actionText = nil
            headerView.separatorView?.isHidden = false
            headerView.sortContainer?.isHidden = true
            headerView.upgradeButton?.isHidden = true
            headerView.label?.text = String(localizationKey: "External_Repo")
            return headerView
        case .ignoredUpdates:
            headerView.actionText = nil
            headerView.separatorView?.isHidden = false
            headerView.sortContainer?.isHidden = true
            headerView.upgradeButton?.isHidden = true
            headerView.label?.text = String(localizationKey: "Ignored Updates")
            return headerView
        case .updates:
            headerView.label?.text = String(localizationKey: "Updates_Heading")
            headerView.actionText = String(localizationKey: "Upgrade_All_Button")
            headerView.sortContainer?.isHidden = true
            headerView.separatorView?.isHidden = true
            headerView.upgradeButton?.addTarget(self, action: #selector(self.upgradeAllClicked(_:)), for: .touchUpInside)
            return headerView
        case .packages:
            if showUpdates {
                headerView.label?.text = String(localizationKey: "Installed_Heading")
                headerView.actionText = nil
                headerView.sortContainer?.isHidden = false
                switch SortMode() {
                case .name: headerView.sortHeader?.text = String(localizationKey: "Sort_Name")
                case .installdate: headerView.sortHeader?.text = String(localizationKey: "Sort_Date")
                case .size: headerView.sortHeader?.text = String(localizationKey: "Sort_Install_Size")
                }
                headerView.sortContainer?.addTarget(self, action: #selector(self.sortPopup(sender:)), for: .touchUpInside)
                headerView.separatorView?.isHidden = false
                return headerView
            } else if showProvisional && loadProvisional {
                headerView.actionText = nil
                headerView.separatorView?.isHidden = false
                headerView.sortContainer?.isHidden = true
                headerView.upgradeButton?.isHidden = true
                headerView.label?.text = String(localizationKey: "Internal_Repo")
                return headerView
            }
        case .reallyBoringList: fatalError("Literally impossible to be here")
        }
        return UICollectionReusableView()
    }
}

extension PackageListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let pvc = self.controller(indexPath: indexPath) else { return }
        self.navigationController?.pushViewController(pvc, animated: true)
    }
}

extension PackageListViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        switch findWhatFuckingSectionThisIs(section) {
        case .reallyBoringList: return .zero
        case .ignoredUpdates, .updates, .canister: return CGSize(width: collectionView.bounds.width, height: 65)
        case .packages:
            return (showUpdates && displaySettings) ? CGSize(width: collectionView.bounds.width, height: 109) : CGSize(width: collectionView.bounds.width, height: 65)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        var width = collectionView.bounds.size.width
        if UIDevice.current.userInterfaceIdiom == .pad || UIApplication.shared.statusBarOrientation.isLandscape {
            if width > 330 {
                width = 330
            }
        }
        return CGSize(width: width, height: 73)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        0
    }
}

extension PackageListViewController: UIViewControllerPreviewingDelegate {
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController? {
        guard let indexPath = collectionView?.indexPathForItem(at: location),
              let pvc = self.controller(indexPath: indexPath)
        else {
            return nil
        }
        return pvc
    }
    
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController) {
        self.navigationController?.pushViewController(viewControllerToCommit, animated: true)
    }
}

@available(iOS 13.0, *)
extension PackageListViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let pvc = self.controller(indexPath: indexPath) else {
            return nil
        }
        
        let menuItems = pvc.actions()
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: {
            pvc
        }, actionProvider: { _ in
            UIMenu(title: "", options: .displayInline, children: menuItems)
        })
        
        return config
    }
    
    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        if let previewController = animator.previewViewController {
            animator.addAnimations {
                self.show(previewController, sender: self)
            }
        }
    }
}

extension PackageListViewController: UISearchBarDelegate {
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        self.provisionalPackages.removeAll()
        self.packages.removeAll()
        self.collectionView?.reloadData()
    }
    
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let text = searchBar.text,
              !text.isEmpty,
              showProvisional,
              loadProvisional
        else {
            return
        }
        CanisterResolver.shared.fetch(text) { change in
            guard change else { return }
            DispatchQueue.main.async {
                self.updateSearchResults(for: self.searchController ?? UISearchController())
            }
        }
    }

    private enum UpdateType {
       case insert
       case delete
       case refresh
       case nothing
   }
   
   @discardableResult private func updateProvisional() -> UpdateType {
       if !showProvisional {
           return .nothing
       }
       
       let text = (searchController?.searchBar.text ?? "").lowercased()
       let oldEmpty = provisionalPackages.isEmpty
       if text.count < 3 {
           self.provisionalPackages.removeAll()
           return oldEmpty ? .nothing : .delete
       }
       
       let all = packages
       self.provisionalPackages = CanisterResolver.shared.packages.filter {(package: ProvisionalPackage) -> Bool in
           let searchTerms = [package.name, package.identifier, package.description, package.author].compactMap { $0?.lowercased() }
           var contains = false
           for term in searchTerms {
               if strstr(term, text) != nil {
                   contains = true
                   break
               }
           }
           if !contains { return false }
           
           if let existingPackage = all.first(where: { $0.packageID == package.identifier }) {
               guard let version = package.version else { return false }
               return DpkgWrapper.isVersion(version, greaterThan: existingPackage.version)
           }
           return true
       }
       if oldEmpty && provisionalPackages.isEmpty {
           return .nothing
       } else if !oldEmpty && provisionalPackages.isEmpty {
           return .delete
       } else if oldEmpty && !provisionalPackages.isEmpty {
           return .insert
       } else {
           return .refresh
       }
   }
}

extension PackageListViewController: UISearchResultsUpdating {
    
    func updateSearchResults(for searchController: UISearchController) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateSearchResults(for: searchController)
            }
            return
        }
        func handleResponse(_ response: UpdateType) {
            switch response {
            case .nothing: return
            case .refresh: collectionView?.reloadSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            case .delete: collectionView?.deleteSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            case .insert: collectionView?.insertSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            }
        }
        
        let searchBar = searchController.searchBar
        self.canisterHeartbeat?.invalidate()
    
        if searchBar.text?.isEmpty ?? true {
            if showSearchField {
                packages = []
                provisionalPackages = []
            }
        } else {
            canisterHeartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                CanisterResolver.shared.fetch(searchBar.text ?? "") { change in
                    guard change else { return }
                    DispatchQueue.main.async {
                        let response = self?.updateProvisional() ?? .nothing
                        handleResponse(response)
                    }
                }
            }
        }
        
        let query = searchBar.text ?? ""
        if query.isEmpty && packagesLoadIdentifier.isEmpty && repoContext == nil {
            collectionView?.reloadData()
            return
        }
        searchingQueue.async {
            self.updatingCount += 1
            
            let packageManager = PackageListManager.shared
            var packages: [Package] = []

            self.showUpdates = query.isEmpty
            
            if let cachedPackages = self.searchCache[query.lowercased()] {
                packages = cachedPackages
            } else if self.packagesLoadIdentifier == "--contextInstalled" {
                guard let context = self.repoContext,
                      let url = context.url else { return }
                let betterContext = RepoManager.shared.repo(with: url) ?? context
                packages = packageManager.packageList(identifier: self.packagesLoadIdentifier,
                                                      search: query,
                                                      sortPackages: true,
                                                      repoContext: nil,
                                                      lookupTable: self.searchCache,
                                                      packagePrepend: betterContext.installed ?? [])
                self.searchCache[query.lowercased()] = packages
            } else {
                packages = packageManager.packageList(identifier: self.packagesLoadIdentifier,
                                                      search: query,
                                                      sortPackages: self.packagesLoadIdentifier != "--installed",
                                                      repoContext: self.repoContext,
                                                      lookupTable: self.searchCache)
                self.searchCache[query.lowercased()] = packages
            }
            
            if self.packagesLoadIdentifier == "--installed" {
                switch SortMode() {
                case .installdate:
                    packages = packages.sorted(by: { package1, package2 -> Bool in
                        guard let date1 = package1.installDate,
                              let date2 = package2.installDate else { return true }
                        return date2.compare(date1) == .orderedAscending
                    })
                case .size:
                    packages = packages.sorted { $0.installedSize ?? 0 > $1.installedSize ?? 0 }
                case .name:
                    packages = packageManager.sortPackages(packages: packages, search: query)
                }
            }
            
            self.updatingCount -= 1
            if self.updatingCount != 0 {
                return
            }
            DispatchQueue.main.async {
                self.packages = packages
                self.updateProvisional()
                
                if self.updatingCount == 0 {
                    UIView.performWithoutAnimation {
                        self.collectionView?.reloadData()
                    }
                }
            }
        }
    }
}

extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

enum PackageListSection {
    case updates
    case ignoredUpdates
    case packages
    case canister
    case reallyBoringList
}
