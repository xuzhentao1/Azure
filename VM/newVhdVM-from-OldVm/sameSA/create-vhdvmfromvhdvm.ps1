﻿function create-vhdVmFromVhdVm{
  param(
  [Parameter(Mandatory=$true)] 
  [String]$csvfilepath
  )
  #$csvfilepath = "D:\Heng\Documents\Git\Azure\VM\newVhdVM-from-OldVm\b.csv"
  #导入CSV文件
  $inputvalues = Import-Csv -Path $csvfilepath 
  #$myinput = $inputvalues[0]
  #对CSV中的内容逐条进行处理
  foreach($myinput in $inputvalues){
    $rgs = Get-AzureRmResourceGroup -Location $myinput.location
    $rgmark = $false
    foreach($rg in $rgs){
      if($rg.ResourceGroupName -eq $myinput.newrgname){$rgmark = $true; break}
    }
    if(!$rgmark){
    New-AzureRmResourceGroup -Name $myinput.newrgname -Location $myinput.location }

    $avsname = $myinput.avsname
    $avss = Get-AzureRmAvailabilitySet -ResourceGroupName $myinput.newrgname
    $avsmark = $false
    foreach($avs in $avss)
    { if($avs.Name -eq $avsname){$avsmark = $true;break}
    }
    if(!$avsmark){$avs = New-AzureRmAvailabilitySet -ResourceGroupName $myinput.newrgname -Name $myinput.avsname -Location $myinput.location -PlatformFaultDomainCount 2}

    $oldvm = Get-AzureRmVM -ResourceGroupName $myinput.oldrgname -Name $myinput.vmname
    #对DISK的类型进行转换
    if($myinput.vmStorageType -eq "Standard_LRS"){$sat = "StandardLRS"}else{$sat = "PremiumLRS"}
    $osduri = $oldvm.StorageProfile.OsDisk.Vhd.Uri
    $saname = $osduri.Split('/')[2].Split('.')[0] 
    $sacname = $osduri.Split('/')[3] 
    $vhdname = $osduri.Split('/')[-1]
    $sas = Get-AzureRmStorageAccount
    foreach($sa in $sas){
        if($saname -eq $sa.StorageAccountName)
        { break
        }
    }
    ################定义新的SA和Container名#########################
    #时间信息
    $daytime = Get-Date -UFormat "%y%m%d"
    #随机数 
    $randomlength = 24 - $myinput.newvmname.Length - 6 - 1
    if($randomlength -ge 5){$randomlength = 5}
    $hash = $null 
    for ($i = 0; $i -le $randomlength; $i++){ 
    $j = (97..122)+(48..57) | Get-Random -Count 1 | % {[char]$_} 
    $hash = $hash + $j }
    $newctrname = $myinput.newvmname + $daytime + $hash
    #$newctrname = $myinput.newCtrName
    ##############定义结束############################################
    $sa | New-AzureStorageContainer -Name $newctrname
    $osdiskblob = $sa | Get-AzureStorageBlob -Container $sacname -Blob $vhdname

    $sa | Get-AzureStorageBlob -Container $sacname -Blob $vhdname | Start-AzureStorageBlobCopy -DestContainer $newctrname

    $newosdiskblob = $sa | Get-AzureStorageBlob -Container $newctrname -Blob $vhdname

    $newosdiskuri = $newosdiskblob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri

    ##################复制data disk的vhd文件#########################################
    #对数据盘进行复制
    $olddatadisks = $oldvm.StorageProfile.DataDisks
    $datadisks = @()
    for($datadiski=1; $datadiski -le $olddatadisks.Count; $datadiski++ )
    {   
        #磁盘名称中加入时间信息
        $daytime = Get-Date -UFormat "%Y%m%d"
        #磁盘名称中加入随机数 
        $hash = $null 
        for ($i = 0; $i -le 5; $i++){ 
        $j = (48..57) | Get-Random -Count 1 | % {[char]$_} 
        $hash = $hash + $j }
        $datadiskname = $myinput.newvmname + "-data" + $datadiski +"-"+ $daytime +"-"+ $hash
        #对数据盘进行复制
        $dduri = $olddatadisks[$datadiski-1].Vhd.Uri
        $dsaname = $dduri.Split('/')[2].Split('.')[0] 
        $dsacname = $dduri.Split('/')[3]
        Write-Output $datadiski
        $dvhdname = $dduri.Split('/')[-1]
        foreach($dsa in $sas){
            if($dsaname -eq $dsa.StorageAccountName)
            { break
            }
        }
        $ddiskblob = $dsa | Get-AzureStorageBlob -Container $dsacname -Blob $dvhdname
        $dsa | Get-AzureStorageBlob -Container $dsacname -Blob $dvhdname | Start-AzureStorageBlobCopy -DestContainer $newctrname
        $newddiskblob = $dsa | Get-AzureStorageBlob -Container $newctrname -Blob $dvhdname
        $newddiskuri = $newddiskblob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri
        #把生成的新磁盘，加入到磁盘数组中
        $datadisks = $datadisks + $newddiskuri
    }

    ##################data disk end##################################################
        
    $vnet = Get-AzureRmVirtualNetwork -Name $myinput.vnetname -ResourceGroupName $myinput.vnetrgname
        
    foreach($subnet in $vnet.Subnets){
        if($subnet.name -eq $myinput.subnetname){
        break
        }
    }
    $vmpipname = $myinput.newvmname + "-pip"
    $vmpip = New-AzureRmPublicIpAddress -Name $vmpipname -ResourceGroupName $myinput.newrgname -Location $myinput.location -AllocationMethod Dynamic
    $vmnicname = $myinput.newvmname + "-nic"
    $vmnic = New-AzureRmNetworkInterface -Name $vmnicname -ResourceGroupName $myinput.newrgname -Location $myinput.location -SubnetId $subnet.Id -PublicIpAddressId $vmpip.Id 
    
    $newvmname = $myinput.newvmname 
    $size = $myinput.vmsize
    $newosdiskname = $newvmname + "OS"
    #创建虚拟机
    #定义VM大小
    $newvm = New-AzureRmVMConfig -VMName $newvmname -VMSize $Size -AvailabilitySetId $avs.Id

    #定义OS盘 
    if($myinput.osType -eq "Linux"){
    $newvm = Set-AzureRmVMOSDisk -VM $newvm -Name $newosdiskname -VhdUri $newosdiskuri -CreateOption Attach -Linux }
    elseif($myinput.osType -eq "Windows"){
    $newvm = Set-AzureRmVMOSDisk -VM $newvm -Name $newosdiskname -VhdUri $newosdiskuri -CreateOption Attach -Windows }
    else{Write-Output "osType should be Linux or Windows";exit}

    #添加启动监控存储账户信息
    $bdsamark = $false
    foreach($bdsa in $sas){
      if($myinput.DiagStorageAccountName -eq $bdsa.StorageAccountName){$bdsamark = $true; break}
    }
    if(!$bdsamark){
    New-AzureRmStorageAccount -ResourceGroupName $myinput.newrgname -Name $myinput.DiagStorageAccountName -SkuName Standard_LRS -Location $myinput.location
    $bdsa = Get-AzureRmStorageAccount -ResourceGroupName $myinput.newrgname -name $myinput.DiagStorageAccountName}
    #输出监控存储账户的信息
    Write-Output $bdsa.ResourceGroupName, $bdsa.StorageAccountName
    $newvm = Set-AzureRmVMBootDiagnostics $newvm -Enable -ResourceGroupName $bdsa.ResourceGroupName -StorageAccountName $bdsa.StorageAccountName
    #添加网卡
    $newvm = Add-AzureRmVMNetworkInterface -VM $newvm -Id $vmnic.id -Primary
    #创建临时VM
    $newvm = New-AzureRmVM -ResourceGroupName $myinput.newrgname -Location $myinput.location -VM $newvm 

    #################添加data disk 盘#################################
    $newvm = Get-AzureRmVM -ResourceGroupName $myinput.newrgname -Name $myinput.newvmname
    for($i=1; $i -le $datadisks.Count; $i++ )
    {
        write-output $i
        write-output $datadisks[$i-1]

        $lun = $i + 1
        $newvm = Add-AzureRmVMDataDisk -VM $newvm -VhdUri $datadisks[$i-1] -Lun $lun -CreateOption Attach -Name $datadisks[$i-1].split('/')[-1]
     }
        
    Update-AzureRmVM -VM $newvm -ResourceGroupName $myinput.newrgname
    Restart-AzureRmVM  -ResourceGroupName $myinput.newrgname -Name $myinput.newvmname 
    #################添加结束#########################################
    
}
   
}

$csvfilepath = "D:\Heng\Documents\Git\Azure\VM\newVhdVM-from-OldVm\b.csv"

create-vhdVmFromVhdVm -csvfilepath $csvfilepath
