Import-Module ActiveDirectory

# Add WinForms and icons libs
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing.Icon

#TODO: admin priv check? seems like yes.
#TODO: activedirectory module check

# get settings from settings file
$settings = Get-Content "$PSScriptRoot\settings.json" 2>$null | ConvertFrom-Json

# set default settings and write settings file if we got nothing
if (!$settings) {

    $rand_id = $(Get-Random -Minimum 1100 -Maximum 9900) * 10000
    $searchbase = Get-ADDomain | Select-Object -ExpandProperty DistinguishedName

    $settings = @{
        user_searchbase = $searchbase
        group_searchbase = $searchbase
        auto_group_min_gidnumber = $rand_id
        auto_user_min_uidnumber = $rand_id
        auto_user_gidnumber = $rand_id
        auto_user_home_prefix = "/home"
        auto_user_shell = "/bin/bash"
    }

    ConvertTo-Json $settings | Out-File "$PSScriptRoot\settings.json"
}

# get and store application icon
$app_icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$PSScriptRoot\icon.ico")


#################
### FUNCTIONS ###
#################

function Get-NextUidNumber([int]$Minimum=1000) {

    $uids = Get-ADUser -Filter * -Properties uidnumber | Select-Object -ExpandProperty uidnumber
    $nextuid = $Minimum
    while ($true) {
        if ($nextuid -in $uids) { $nextuid = $nextuid + 1 }
        else { return $nextuid }
    }
}

function Get-NextGidNumber([int]$Minimum=1000) {

    $gids = Get-ADGroup -Filter * -Properties gidnumber | Select-Object -ExpandProperty gidnumber
    $nextgid = $Minimum
    while ($true) {
        if ($nextgid -in $gids) { $nextgid = $nextgid + 1 }
        else { return $nextgid }
    }
}

function Set-ADUnixUser([string]$Identity, [int]$uidNumber, [int]$gidNumber, [string]$unixHomeDirectory, [string]$loginShell) {
    
    # if uidnumber is empty, clear unix attrs and return
    if (!$uidNumber) {
        Set-ADUser -Identity $Identity -Clear uidNumber,gidNumber,unixHomeDirectory,loginShell
        return
    }

    # verify uidNumber is not already in use
    $uids = Get-ADUser -Filter * -Properties uidnumber | Select-Object -ExpandProperty uidnumber
    if ($uidNumber -in $uids) {

        $uidownername = (Get-ADUser -Filter "uidNumber -eq $uidNumber").SamAccountName
        
        if (-not ($Identity -eq $uidownername)) {
            throw "uidNumber $uidNumber already assigned to user: $uidownername"
        }
    }

    # set user unix attributes
    $attrs = @{
        uidNumber = $uidNumber
        gidNumber = $gidNumber
        unixHomeDirectory = $unixHomeDirectory
        loginShell = $loginShell
    }
    Set-ADUser -Identity $Identity -Replace $attrs
}

function Set-ADUnixGroup([string]$Identity, [int]$gidNumber) {

    # if gidnumber is empty, clear unix attrs and return
    if (!$gidNumber) {
        Set-ADGroup -Identity $Identity -Clear gidNumber
        return
    }

    # verify gidNumber is not already in use
    $gids = Get-ADGroup -Filter * -Properties gidnumber | Select-Object -ExpandProperty gidnumber
    if ($gidNumber -in $gids) {

        $gidownername = (Get-ADGroup -Filter "gidNumber -eq $gidNumber").SamAccountName
        
        if (-not ($Identity -eq $gidownername)) {
            throw "gidNumber $gidNumber already assigned to group: $gidownername"
        }
    }

    # set group unix attributes
    Set-ADGroup -Identity $Identity -Replace @{ gidNumber = $gidNumber }
}

function Get-ADUserFilter([string]$NameContains, [switch]$EnabledOnly, [switch]$UnixOnly) {
    
    $filter = @()
    
    if ($NameContains) { $filter += "(Name -like '*$NameContains*' -or SamAccountName -like '*$NameContains*')" }
    if ($EnabledOnly) { $filter += 'Enabled -eq $true' }
    if ($UnixOnly) { $filter += 'uidNumber -like "*"' }
    if (!$filter) { $filter += '*' }

    return $filter -join ' -and '
}

function Get-ADGroupFilter([string]$NameContains, [switch]$UnixOnly) {
    
    $filter = @()
    
    if ($NameContains) { $filter += "(Name -like '*$NameContains*' -or SamAccountName -like '*$NameContains*')" }
    if ($UnixOnly) { $filter += 'gidNumber -like "*"' }
    if (!$filter) { $filter += '*' }

    return $filter -join ' -and '
}


#######################
### GUI - FUNCTIONS ###
#######################

function ed_save_click() {

    if ($tabcontrol.SelectedTab -eq $usertab) {
        
        # set user attributes
        $setuser_params = @{
            uidNumber = $ed_uidnumber_tb.Text
            gidNumber = $ed_gidnumber_tb.Text
            unixHomeDirectory = $ed_unixhome_tb.Text
            loginShell = $ed_loginshell_tb.Text
        }
        Set-ADUnixUser -Identity $ed_samaccountname_tb.Text @setuser_params

        # refresh row in the table
        $adobject = Get-ADObject -Filter { SamAccountName -eq $ed_samaccountname_tb.Text } -Properties *
        $newvalues = @(
            $adobject.Name
            $adobject.SamAccountName
            $adobject.uidNumber
            $adobject.gidNumber
            $adobject.unixHomeDirectory
            $adobject.loginShell
        )
        $userdatagrid.SelectedRows[0].SetValues($newvalues)
    }
    else {

        # set group attributes
        Set-ADUnixGroup -Identity $adobject.SamAccountName -gidNumber $ed_gidnumber_tb.Text

        # refresh row in the table
        $adobject = Get-ADObject -Filter { SamAccountName -eq $ed_samaccountname_tb.Text } -Properties *
        $newvalues = @(
            $adobject.Name
            $adobject.SamAccountName
            $adobject.gidNumber
        )
        $groupdatagrid.SelectedRows[0].SetValues($newvalues)
    }

    $editdialog.Hide()
}

function ed_autofill_click(){
    if ((Get-ADObject -Filter { SamAccountName -eq $ed_samaccountname_tb.Text }).ObjectClass -eq "user") {
        
        if (!$ed_uidnumber_tb.Text) { $ed_uidnumber_tb.Text = Get-NextUidNumber -Minimum $settings.auto_user_min_uidnumber }
        if (!$ed_gidnumber_tb.Text) { $ed_gidnumber_tb.Text = $settings.auto_user_gidnumber }
        if (!$ed_unixhome_tb.Text) { $ed_unixhome_tb.Text = $settings.auto_user_home_prefix + "/" + $ed_samaccountname_tb.Text }
        if (!$ed_loginshell_tb.Text) { $ed_loginshell_tb.Text = $settings.auto_user_shell }
    }
    else {

        if (!$ed_gidnumber_tb.Text) { $ed_gidnumber_tb.Text = Get-NextGidNumber -Minimum $settings.auto_group_min_gidnumber }
    }
}

function ed_clear_click() {
    $ed_uidnumber_tb.Text = ""
    $ed_gidnumber_tb.Text = ""
    $ed_unixhome_tb.Text = ""
    $ed_loginshell_tb.Text = ""
}

function ed_cancel_click() {
    $editdialog.Hide()
}

function edit_click() {

    if ($tabcontrol.SelectedTab -eq $usertab) {

        # enable user-edit only controls
        $ed_uidnumber_tb.Enabled = $true
        $ed_unixhome_tb.Enabled = $true
        $ed_loginshell_tb.Enabled = $true

        # get id of selected user
        $SamAccountName = $userdatagrid.SelectedRows[0].Cells[1].Value
    }
    else {

        # disable user-edit only controls
        $ed_uidnumber_tb.Enabled = $false
        $ed_unixhome_tb.Enabled = $false
        $ed_loginshell_tb.Enabled = $false

        # get id of selected group
        $SamAccountName = $groupdatagrid.SelectedRows[0].Cells[1].Value
    }

    # get the user or group and fill out the dialog
    $adobject = Get-ADObject -Filter { SamAccountName -eq $SamAccountName } -Properties *
    $editdialog.Text = "Edit: " + $adobject.Name
    $ed_samaccountname_tb.Text = $adobject.SamAccountName
    $ed_uidnumber_tb.Text = $adobject.uidNumber
    $ed_gidnumber_tb.Text = $adobject.gidNumber
    $ed_unixhome_tb.Text = $adobject.unixHomeDirectory
    $ed_loginshell_tb.Text = $adobject.loginShell

    # set size and show edit dialog
    $editdialog.ShowDialog()
}

function refresh_click() {

    $user_filter_params = @{
        NameContains = $namecontains_tb.Text
        EnabledOnly = $enabledonly_cb.Checked
        UnixOnly = $unixonly_cb.Checked
    }
    $group_filter_params = @{
        NameContains = $namecontains_tb.Text
        UnixOnly = $unixonly_cb.Checked
    }
    $get_aduser_params = @{
        Filter = Get-ADUserFilter @user_filter_params
        SearchBase = $settings.user_searchbase
        Properties = "Name","SamAccountName","uidNumber","gidNumber","unixHomeDirectory","loginShell"
    }
    $get_adgroup_params = @{
        Filter = Get-ADGroupFilter @group_filter_params
        SearchBase = $settings.group_searchbase
        Properties = "Name","SamAccountName","gidNumber"
    }

    $userdatagrid.Rows.Clear()
    foreach ($u in Get-ADUser @get_aduser_params) {
        $userdatagrid.Rows.Add($u.Name,$u.SamAccountName,$u.uidNumber,$u.gidNumber,$u.unixHomeDirectory,$u.loginShell)
    }

    $groupdatagrid.Rows.Clear()
    foreach ($g in Get-ADGroup @get_adgroup_params) {
        $groupdatagrid.Rows.Add($g.Name,$g.SamAccountName,$g.gidNumber)
    }
}

#########################
### GUI - EDIT DIALOG ###
#########################

$ed_samaccountname_lab = New-Object System.Windows.Forms.Label
$ed_samaccountname_lab.Text = "SamAccountName"

$ed_samaccountname_tb = New-Object System.Windows.Forms.TextBox
$ed_samaccountname_tb.Dock = "Fill"
$ed_samaccountname_tb.Enabled = $false

$ed_uidnumber_lab = New-Object System.Windows.Forms.Label
$ed_uidnumber_lab.Text = "uidNumber"

$ed_uidnumber_tb = New-Object System.Windows.Forms.TextBox
$ed_uidnumber_tb.Dock = "Fill"

$ed_gidnumber_lab = New-Object System.Windows.Forms.Label
$ed_gidnumber_lab.Text = "gidNumber"

$ed_gidnumber_tb = New-Object System.Windows.Forms.TextBox
$ed_gidnumber_tb.Dock = "Fill"

$ed_unixhome_lab = New-Object System.Windows.Forms.Label
$ed_unixhome_lab.Text = "unixHomeDirectory"
$ed_unixhome_lab.AutoSize = $true

$ed_unixhome_tb = New-Object System.Windows.Forms.TextBox
$ed_unixhome_tb.Dock = "Fill"

$ed_loginshell_lab = New-Object System.Windows.Forms.Label
$ed_loginshell_lab.Text = "loginShell"

$ed_loginshell_tb = New-Object System.Windows.Forms.TextBox
$ed_loginshell_tb.Dock = "Fill"

$ed_clearbutton = New-Object System.Windows.Forms.Button
$ed_clearbutton.Text = "Clear"
$ed_clearbutton.Anchor = "Bottom,Left"
$ed_clearbutton.Add_Click({ ed_clear_click })

$ed_autofillbutton = New-Object System.Windows.Forms.Button
$ed_autofillbutton.Text = "Autofill"
$ed_autofillbutton.Anchor = "Bottom,Right"
$ed_autofillbutton.Add_Click({ ed_autofill_click })

$ed_cancelbutton = New-Object System.Windows.Forms.Button
$ed_cancelbutton.Text = "Cancel"
$ed_cancelbutton.Anchor = "Bottom,Left"
$ed_cancelbutton.Add_Click({ ed_cancel_click })

$ed_savebutton = New-Object System.Windows.Forms.Button
$ed_savebutton.Text = "Save"
$ed_savebutton.Anchor = "Bottom,Right"
$ed_savebutton.Add_Click({ ed_save_click })

$ed_controlpanel = New-Object System.Windows.Forms.TableLayoutPanel
$ed_controlpanel.Dock = "Fill"
#$ed_controlpanel.CellBorderStyle = "Single"
$ed_controlpanel.Controls.Add($ed_samaccountname_lab, 0, 0)
$ed_controlpanel.Controls.Add($ed_samaccountname_tb, 1, 0)
$ed_controlpanel.Controls.Add($ed_uidnumber_lab, 0, 1)
$ed_controlpanel.Controls.Add($ed_uidnumber_tb, 1, 1)
$ed_controlpanel.Controls.Add($ed_gidnumber_lab, 0, 2)
$ed_controlpanel.Controls.Add($ed_gidnumber_tb, 1, 2)
$ed_controlpanel.Controls.Add($ed_unixhome_lab, 0, 3)
$ed_controlpanel.Controls.Add($ed_unixhome_tb, 1, 3)
$ed_controlpanel.Controls.Add($ed_loginshell_lab, 0, 4)
$ed_controlpanel.Controls.Add($ed_loginshell_tb, 1, 4)
$ed_controlpanel.Controls.Add($ed_clearbutton, 0, 5)
$ed_controlpanel.Controls.Add($ed_autofillbutton, 1, 5)
$ed_controlpanel.Controls.Add($ed_cancelbutton, 0, 6)
$ed_controlpanel.Controls.Add($ed_savebutton, 1, 6)

$editdialog = New-Object System.Windows.Forms.Form
$editdialog.Text = "Edit"
$editdialog.Size = "300,240"
$editdialog.FormBorderStyle = "FixedSingle"
$editdialog.Icon = $app_icon
$editdialog.MinimizeBox = $false
$editdialog.MaximizeBox = $false
$editdialog.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
$editdialog.Controls.Add($ed_controlpanel)


#########################
### GUI - MAIN WINDOW ###
#########################

$editbutton = New-Object System.Windows.Forms.Button
$editbutton.AutoSize = $true
$editbutton.Anchor = "Right"
$editbutton.Text = "Edit"
$editbutton.Add_Click({ edit_click })

$refreshbutton = New-Object System.Windows.Forms.Button
$refreshbutton.AutoSize = $true
$refreshbutton.Anchor = "Right"
$refreshbutton.Text = "Refresh"
$refreshbutton.Add_Click({ refresh_click })

$namecontains_tb = New-Object System.Windows.Forms.TextBox
$namecontains_tb.Dock = "Fill"

$namecontains_lab = New-Object System.Windows.Forms.Label
$namecontains_lab.Dock = "Left"
$namecontains_lab.Text = "Name contains:"
$namecontains_lab.AutoSize = $true

$namecontainspanel = New-Object System.Windows.Forms.Panel
$namecontainspanel.Dock = "Bottom"
$namecontainspanel.Height = $namecontains_tb.Height
$namecontainspanel.Width = 300
$namecontainspanel.Controls.AddRange(@($namecontains_tb, $namecontains_lab))

$enabledonly_cb = New-Object System.Windows.Forms.CheckBox
$enabledonly_cb.AutoSize = $true
$enabledonly_cb.Text = "Enabled Only"
$enabledonly_cb.Checked = $true

$unixonly_cb = New-Object System.Windows.Forms.CheckBox
$unixonly_cb.AutoSize = $true
$unixonly_cb.Text = "Unix Only"

$controlpanel = New-Object System.Windows.Forms.TableLayoutPanel
$controlpanel.Dock = "Bottom"
$controlpanel.AutoSize = $true
#$controlpanel.CellBorderStyle = "Single"
$controlpanel.Controls.Add($namecontainspanel, 0, 0)
$controlpanel.SetColumnSpan($namecontainspanel, 2)
$controlpanel.Controls.Add($editbutton, 2, 0)
$controlpanel.Controls.Add($enabledonly_cb, 0, 1)
$controlpanel.Controls.Add($unixonly_cb, 1, 1)
$controlpanel.Controls.Add($refreshbutton, 2, 1)

$userdatagrid = New-Object System.Windows.Forms.DataGridView
$userdatagrid.Dock = "Fill"
$userdatagrid.AutoSizeColumnsMode = 6
$userdatagrid.ReadOnly = $true
$userdatagrid.RowHeadersVisible = $false
$userdatagrid.AllowUserToResizeRows = $false
$userdatagrid.AllowUserToAddRows = $false
$userdatagrid.SelectionMode = "FullRowSelect"
$userdatagrid.MultiSelect = $false
$userdatagrid.Add_DoubleClick({ edit_click })
$userdatagrid.Columns.Add("Name", "Name")
$userdatagrid.Columns.Add("SamAccountName", "SamAccountName")
$userdatagrid.Columns.Add("uidNumber", "uidNumber")
$userdatagrid.Columns.Add("gidNumber", "gidNumber")
$userdatagrid.Columns.Add("unixHomeDirectory", "unixHomeDirectory")
$userdatagrid.Columns.Add("loginShell", "loginShell")

$groupdatagrid = New-Object System.Windows.Forms.DataGridView
$groupdatagrid.Dock = "Fill"
$groupdatagrid.AutoSizeColumnsMode = 6
$groupdatagrid.ReadOnly = $true
$groupdatagrid.RowHeadersVisible = $false
$groupdatagrid.AllowUserToResizeRows = $false
$groupdatagrid.AllowUserToAddRows = $false
$groupdatagrid.SelectionMode = "FullRowSelect"
$groupdatagrid.MultiSelect = $false
$groupdatagrid.Add_DoubleClick({ edit_click })
$groupdatagrid.Columns.Add("Name", "Name")
$groupdatagrid.Columns.Add("SamAccountName", "SamAccountName")
$groupdatagrid.Columns.Add("gidNumber", "gidNumber")

$usertab = New-Object System.Windows.Forms.TabPage
$usertab.Text = "Users"
$usertab.Controls.Add($userdatagrid)

$grouptab = New-Object System.Windows.Forms.TabPage
$grouptab.Text = "Groups"
$grouptab.Controls.Add($groupdatagrid)

$tabcontrol = New-Object System.Windows.Forms.TabControl
$tabcontrol.Dock = "Fill"
$tabcontrol.TabPages.Add($usertab)
$tabcontrol.TabPages.Add($grouptab)

$mainwindow = New-Object System.Windows.Forms.Form
$mainwindow.Size = "640,600"
$mainwindow.Padding = New-Object System.Windows.Forms.Padding(2, 2, 2, 16)
$mainwindow.Text = "ADUnixEdit"
$mainwindow.Controls.AddRange(@($tabcontrol, $controlpanel))
$mainwindow.AcceptButton = $refreshbutton
$mainwindow.Icon = $app_icon

# error handling
function handle_err($err) {
    [System.Windows.Forms.MessageBox]::Show($err.Message, "ERROR", 0, 16)
}
[Windows.Forms.Application]::add_ThreadException({ handle_err $_.Exception })
trap {}

# refresh tables and run
refresh_click
[Windows.Forms.Application]::Run($mainwindow)