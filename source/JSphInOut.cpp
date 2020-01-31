//HEAD_DSPH
/*
 <DUALSPHYSICS>  Copyright (c) 2016, Dr Jose M. Dominguez et al. (see http://dual.sphysics.org/index.php/developers/). 

 EPHYSLAB Environmental Physics Laboratory, Universidade de Vigo, Ourense, Spain.
 School of Mechanical, Aerospace and Civil Engineering, University of Manchester, Manchester, U.K.

 This file is part of DualSPHysics. 

 DualSPHysics is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or (at your option) any later version. 

 DualSPHysics is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. 

 You should have received a copy of the GNU General Public License, along with DualSPHysics. If not, see <http://www.gnu.org/licenses/>. 
*/

/// \file JSphInOut.cpp \brief Implements the class \ref JSphInOut.

#include "JSphInOut.h"
#include "JSphInOutPoints.h"
#include "JSphInOutGridData.h"
#include "JSphCpu.h"
#include "JSphMk.h"
#include "JXml.h"
#include "JLog2.h"
#include "JAppInfo.h"
#include "Functions.h"
#include "FunctionsMath.h"
#include "FunctionsGeo3d.h"
#include "JMatrix4.h"
#include "JLinearValue.h"
#include "JRangeFilter.h"
#include "JFormatFiles2.h"

#ifdef _WITHGPU
#include "FunctionsCuda.h"
  #include "JSphGpu_InOut_ker.h"
#endif

#include <cfloat>
#include <climits>
#include <algorithm>

using namespace std;

//##############################################################################
//# JSphInOutZone
//##############################################################################
//==============================================================================
/// Constructor.
//==============================================================================
JSphInOutZone::JSphInOutZone(bool cpu,JLog2 *log,unsigned idzone,bool simulate2d,double simulate2dposy
  ,double dp,const tdouble3 &posmin,const tdouble3 &posmax,JXml *sxml,TiXmlElement* ele
  ,const std::string &dirdatafile,const JSphPartsInit *partsdata)
 :Cpu(cpu),Log(log),IdZone(idzone),Simulate2D(simulate2d),Simulate2DPosY(simulate2dposy)
 ,Dp(dp),MapRealPosMin(posmin),MapRealPosMax(posmax)
{
  ClassName="JSphInOutZone";
  Points=NULL;
  TimeInputVelData=NULL;
  InputVelGrid=NULL;
  TimeInputZsurf=NULL;
  PtzPos=NULL;
  #ifdef _WITHGPU
    PtzPosg=NULL; PtzAuxg=NULL; PtzAux=NULL;
  #endif

  Reset();
  ReadXml(sxml,ele,dirdatafile,partsdata);
}

//==============================================================================
/// Destructor.
//==============================================================================
JSphInOutZone::~JSphInOutZone(){
  DestructorActive=true;
  Reset();
}

//==============================================================================
/// Initialisation of variables.
//==============================================================================
void JSphInOutZone::Reset(){
  delete Points; Points=NULL;
  delete TimeInputVelData; TimeInputVelData=NULL;
  delete InputVelGrid; InputVelGrid=NULL;
  ResetZVelGrid=false;
  TimeVelIdx0=TimeVelIdx1=UINT_MAX; 
  SaveVelProfile=true;
  delete TimeInputZsurf; TimeInputZsurf=NULL;
  Layers=0;
  ConvertFluid=false;
  for(unsigned c=0;c<10;c++)PtDom[c]=TDouble3(DBL_MAX);
  BoxLimitMin=BoxLimitMax=TFloat3(FLT_MAX);
  VelMode=MVEL_Fixed;
  VelProfile=PVEL_Constant;
  InputVel=InputVel2=InputVel3=0;
  InputVelPosz=InputVelPosz2=InputVelPosz3=0;
  RhopMode=MRHOP_Constant;
  ZsurfMode=ZSURF_Undefined;
  InputZsurf=InputZbottom=FLT_MAX;
  RemoveZsurf=false;
  SvVtkZsurf=false;
  ExternalVarInput=false;
  RevNewnpPerSec=true;
  NewnpPerSec=0;
  Direction=PtPlane=TDouble3(0);
  Plane=TPlane3f(0);
  NptInit=NpartInit=0;
  delete[] PtzPos;  PtzPos=NULL;
  #ifdef _WITHGPU
    if(PtzPosg)cudaFree(PtzPosg);  PtzPosg=NULL;
    if(PtzAuxg)cudaFree(PtzAuxg);  PtzAuxg=NULL;
    delete[] PtzAux;  PtzAux=NULL;
  #endif
}

//==============================================================================
/// Loads lines with configuration information.
//==============================================================================
void JSphInOutZone::GetConfig(std::vector<std::string> &lines)const{
  Points->GetConfig(lines);
  if(Simulate2D)lines.push_back(fun::PrintStr("Inlet Position(x,z): (%g,%g)",PtPlane.x,PtPlane.z));
  else          lines.push_back(fun::PrintStr("Inlet Position: (%g,%g,%g)",PtPlane.x,PtPlane.y,PtPlane.z));
  if(Simulate2D)lines.push_back(fun::PrintStr("Inlet Direction(x,z): (%g,%g)",Direction.x,Direction.z));
  else          lines.push_back(fun::PrintStr("Inlet Direction: (%g,%g,%g)",Direction.x,Direction.y,Direction.z));
  lines.push_back(fun::PrintStr("InOut points: %u",NptInit));
  lines.push_back(fun::PrintStr("Initial InOut particles: %u",NpartInit));
  lines.push_back(fun::PrintStr("Layers: %u",Layers));
  lines.push_back(fun::PrintStr("Convert fluid: %s",(ConvertFluid? "True": "False")));
  if(VelMode==MVEL_Fixed || VelMode==MVEL_Variable){
    lines.push_back(fun::PrintStr("Velocity mode: %s",(VelMode==MVEL_Fixed? "Fixed": "Variable")));
    if(VelMode==MVEL_Variable && !TimeInputVelData->GetFile().empty())lines.push_back(fun::PrintStr("  Velocity file: %s",TimeInputVelData->GetFile().c_str()));
    if(VelProfile==PVEL_Constant )lines.push_back(fun::PrintStr("  Velocity profile: Constant %g",InputVel));
    if(VelProfile==PVEL_Linear   )lines.push_back(fun::PrintStr("  Velocity profile: Linear %g(z=%g), %g(z=%g)",InputVel,InputVelPosz,InputVel2,InputVelPosz2));
    if(VelProfile==PVEL_Parabolic)lines.push_back(fun::PrintStr("  Velocity profile: Parabolic %g(z=%g), %g(z=%g), %g(z=%g)",InputVel,InputVelPosz,InputVel2,InputVelPosz2,InputVel3,InputVelPosz3));
  }
  else if(VelMode==MVEL_Extrapolated)lines.push_back("Velocity mode: Extrapolated");
  else if(VelMode==MVEL_Interpolated){
    lines.push_back("Velocity mode: Interpolated");
    lines.push_back(fun::PrintStr("  Velocity file: %s",InputVelGrid->GetFile().c_str()));
    lines.push_back(fun::PrintStr("  Reset Z velocity: %s",(ResetZVelGrid? "True": "False")));
  }
  else lines.push_back("???");
//  if(VelMode==MVEL_Fixed)lines.push_back(fun::PrintStr("New particles per second: %.1f",NewnpPerSec));
  lines.push_back(fun::PrintStr("Rhop mode: %s",(RhopMode==MRHOP_Constant? "Constant": (RhopMode==MRHOP_Hydrostatic? "Hydrostatic": (RhopMode==MRHOP_Extrapolated? "Extrapolated": "???")))));
  lines.push_back(fun::PrintStr("Z-Surface mode: %s",(ZsurfMode==ZSURF_Undefined? "Undefined": (ZsurfMode==ZSURF_Fixed? "Fixed": (ZsurfMode==ZSURF_Variable? "Variable": (ZsurfMode==ZSURF_Calculated? "Calculated": "???"))))));
  if(ZsurfMode==ZSURF_Variable && !TimeInputZsurf->GetFile().empty())lines.push_back(fun::PrintStr("Zsurf file: %s",TimeInputZsurf->GetFile().c_str()));
  if(ZsurfMode!=ZSURF_Undefined || RhopMode==MRHOP_Hydrostatic){
    lines.push_back(fun::PrintStr("  Z-Surface value (initial): %g",InputZsurf));
    lines.push_back(fun::PrintStr("  Z-Bottom value: %g",InputZbottom));
  }
  if(ZsurfMode!=ZSURF_Undefined){
    lines.push_back(fun::PrintStr("  Z-Surface Remove: %s",(RemoveZsurf? "True": "False")));
    lines.push_back(fun::PrintStr("  Z-Surface SaveVTK: %s",(SvVtkZsurf? "True": "False")));
  }
}

//==============================================================================
/// Loads domain and calculates BoxLimitMin/Max.
//==============================================================================
void JSphInOutZone::LoadDomain(){
  //-Obtains domain data from Points object.
  const tdouble3* ptdom=Points->GetPtDomain();
  for(unsigned c=0;c<10;c++)PtDom[c]=ptdom[c];
  //-Calculates BoxLimit.
  tdouble3 pmin=PtDom[0],pmax=PtDom[0];
  for(unsigned c=1;c<unsigned(Simulate2D? 4: 8);c++){
    const tdouble3 ps=PtDom[c];
    pmin=MinValues(pmin,ps);
    pmax=MaxValues(pmax,ps);
  }
  BoxLimitMin=ToTFloat3(pmin);
  BoxLimitMax=ToTFloat3(pmax);
  ////-Adds border of size Scell.
  //BoxLimitMin=ToTFloat3(pmin-TDouble3(Scell));
  //BoxLimitMax=ToTFloat3(pmax+TDouble3(Scell));
}

//==============================================================================
/// Reads initial configuration in the XML node.
//==============================================================================
void JSphInOutZone::ReadXml(JXml *sxml,TiXmlElement* ele,const std::string &dirdatafile
  ,const JSphPartsInit *partsdata)
{
  const char met[]="ReadXml";
  //-Loads ConvertFluid.
  ConvertFluid=sxml->ReadElementBool(ele,"convertfluid","value",true,true);
  //-Loads layers value.
  unsigned layers=sxml->ReadElementUnsigned(ele,"layers","value");
  if(layers<1)sxml->ErrReadElement(ele,"layers",false,"Minumum number of layers is 1.");
  if(layers>250)sxml->ErrReadElement(ele,"layers",false,"Maximum number of layers is 250.");
  Layers=byte(layers);
  //-Creates inlet points.
  Points=new JSphInOutPoints(Log,Simulate2D,Simulate2DPosY,Layers,Dp,0,MapRealPosMin,MapRealPosMax);
  if(Simulate2D){
    TiXmlElement* zone2d=ele->FirstChildElement("zone2d"); 
    if(zone2d)Points->CreatePoints(sxml,zone2d,partsdata);
    else sxml->ErrReadElement(ele,"zone2d",true);
  }
  else{
    TiXmlElement* zone3d=ele->FirstChildElement("zone3d"); 
    if(zone3d)Points->CreatePoints(sxml,zone3d,partsdata);
    else sxml->ErrReadElement(ele,"zone3d",true);
  }
  //-Obtains domain data from Points object.
  LoadDomain();

  //-Obtains information inlet/outlet points.
  Direction=Points->GetDirection();
  PtPlane=PtDom[8];
  if(PtPlane==TDouble3(DBL_MAX))RunException(met,"Reference point in inout plane is invalid.");
  Plane=TPlane3f(fgeo::PlanePtVec(PtPlane,Direction));
  NptInit=Points->GetCount();
  //-Velocity configuration.
  TiXmlElement* xele=ele->FirstChildElement("imposevelocity");
  if(xele){
    const unsigned mode=sxml->GetAttributeUint(xele,"mode",true);
    switch(mode){
      case 0:  VelMode=MVEL_Fixed;         break;
      case 1:  VelMode=MVEL_Variable;      break;
      case 2:  VelMode=MVEL_Extrapolated;  break;
      case 3:  VelMode=MVEL_Interpolated;  break;
      default: sxml->ErrReadAtrib(xele,"mode",false,"Value is not valid.");
    }
    if(VelMode==MVEL_Fixed){
      const byte vel1=(sxml->ExistsElement(xele,"velocity" )? 1: 0);
      const byte vel2=(sxml->ExistsElement(xele,"velocity2")? 1: 0);
      const byte vel3=(sxml->ExistsElement(xele,"velocity3")? 1: 0);
      if(vel1+vel2+vel3>1)sxml->ErrReadElement(xele,"velocity",false,"Several definitions for velocity were found.");
      if(vel1 || vel1+vel2+vel3==0){
        VelProfile=PVEL_Constant;
        InputVel=sxml->ReadElementFloat(xele,"velocity","v");
      }
      if(vel2){
        VelProfile=PVEL_Linear;
        InputVel=sxml->ReadElementFloat(xele,"velocity2","v");
        InputVel2=sxml->ReadElementFloat(xele,"velocity2","v2");
        InputVelPosz=sxml->ReadElementFloat(xele,"velocity2","z");
        InputVelPosz2=sxml->ReadElementFloat(xele,"velocity2","z2");
      }
      if(vel3){
        VelProfile=PVEL_Parabolic;
        InputVel =sxml->ReadElementFloat(xele,"velocity3","v");
        InputVel2=sxml->ReadElementFloat(xele,"velocity3","v2");
        InputVel3=sxml->ReadElementFloat(xele,"velocity3","v3");
        InputVelPosz =sxml->ReadElementFloat(xele,"velocity3","z");
        InputVelPosz2=sxml->ReadElementFloat(xele,"velocity3","z2");
        InputVelPosz3=sxml->ReadElementFloat(xele,"velocity3","z3");
      }
    }
    else if(VelMode==MVEL_Variable){
      const unsigned NTMIN=50;
      const byte vel1= (sxml->ExistsElement(xele,"velocitytimes" )? 1: 0);
      const byte vel2= (sxml->ExistsElement(xele,"velocitytimes2")? 1: 0);
      const byte vel3= (sxml->ExistsElement(xele,"velocitytimes3")? 1: 0);
      const byte vel1f=(sxml->ExistsElement(xele,"velocityfile"  )? 1: 0);
      const byte vel2f=(sxml->ExistsElement(xele,"velocityfile2" )? 1: 0);
      const byte vel3f=(sxml->ExistsElement(xele,"velocityfile3" )? 1: 0);
      if(vel1+vel2+vel3+vel1f+vel2f+vel3f>1)sxml->ErrReadElement(xele,"velocitytimes/velocityfile",false,"Several definitions for velocity were found.");
      if(vel1+vel2+vel3+vel1f+vel2f+vel3f==0)sxml->ErrReadElement(xele,"velocitytimes/velocityfile",false,"No definitions for variable velocity were found.");
      if(vel1 || vel1f){
        VelProfile=PVEL_Constant;
        TimeInputVelData=new JLinearValue(1);
        TiXmlElement* xlis=xele->FirstChildElement("velocitytimes");
        if(xlis){
          TimeInputVelData->SetSize(NTMIN);
          TiXmlElement* elet=xlis->FirstChildElement("timevalue"); 
          while(elet){
            double t=sxml->GetAttributeDouble(elet,"time");
            double v=sxml->GetAttributeDouble(elet,"v");
            TimeInputVelData->AddTimeValue(t,v);
            elet=elet->NextSiblingElement("timevalue");
          }
        }
        else{
          TimeInputVelData->LoadFile(dirdatafile+sxml->ReadElementStr(xele,"velocityfile","file"));
        }
      }
      if(vel2 || vel2f){
        VelProfile=PVEL_Linear;
        TimeInputVelData=new JLinearValue(4);
        TiXmlElement* xlis=xele->FirstChildElement("velocitytimes2");
        if(xlis){
          TimeInputVelData->SetSize(NTMIN);
          TiXmlElement* elet=xlis->FirstChildElement("timevalue"); 
          while(elet){
            double t=sxml->GetAttributeDouble(elet,"time");
            double v=sxml->GetAttributeDouble(elet,"v");
            double v2=sxml->GetAttributeDouble(elet,"v2");
            double z=sxml->GetAttributeDouble(elet,"z");
            double z2=sxml->GetAttributeDouble(elet,"z2");
            TimeInputVelData->AddTimeValue(t,v,v2,z,z2);
            elet=elet->NextSiblingElement("timevalue");
          }
        }
        else{
          TimeInputVelData->LoadFile(dirdatafile+sxml->ReadElementStr(xele,"velocityfile2","file"));
        }
      }
      if(vel3 || vel3f){
        VelProfile=PVEL_Parabolic;
        TimeInputVelData=new JLinearValue(6);
        TiXmlElement* xlis=xele->FirstChildElement("velocitytimes3");
        if(xlis){
          TimeInputVelData->SetSize(NTMIN);
          TiXmlElement* elet=xlis->FirstChildElement("timevalue"); 
          while(elet){
            double t=sxml->GetAttributeDouble(elet,"time");
            double v=sxml->GetAttributeDouble(elet,"v");
            double v2=sxml->GetAttributeDouble(elet,"v2");
            double v3=sxml->GetAttributeDouble(elet,"v3");
            double z=sxml->GetAttributeDouble(elet,"z");
            double z2=sxml->GetAttributeDouble(elet,"z2");
            double z3=sxml->GetAttributeDouble(elet,"z3");
            TimeInputVelData->AddTimeValue(t,v,v2,v3,z,z2,z3);
            elet=elet->NextSiblingElement("timevalue");
          }
        }
        else{
          TimeInputVelData->LoadFile(dirdatafile+sxml->ReadElementStr(xele,"velocityfile3","file"));
        }
      }
      if(!TimeInputVelData || TimeInputVelData->GetCount()<1)RunException(met,"There are not inlet/outlet velocity values.");
    }
    else if(VelMode==MVEL_Interpolated){
      InputVelGrid=new JSphInOutGridData(Log);
      InputVelGrid->ConfigFromFile(dirdatafile+sxml->ReadElementStr(xele,"gridveldata","file"));
      ResetZVelGrid=sxml->ReadElementBool(xele,"gridresetvelz","value",true,false);
      double xmin=sxml->ReadElementDouble(xele,"gridposzero","x",true,0);
      double zmin=sxml->ReadElementDouble(xele,"gridposzero","z",true,0);
      InputVelGrid->SetPosMin(TDouble3(xmin,(Simulate2D? Simulate2DPosY: MapRealPosMin.y),zmin));
    }
    else if(VelMode!=MVEL_Extrapolated)RunException(met,"Inlet/outlet velocity profile is unknown.");
  }
  else sxml->ErrReadElement(ele,"imposevelocity",true);

  //-Z-surface configuration.
  xele=ele->FirstChildElement("imposezsurf");
  if(xele){
    const unsigned mode=sxml->GetAttributeUint(xele,"mode",true);
    switch(mode){
      case 0:  ZsurfMode=ZSURF_Fixed;       break;
      case 1:  ZsurfMode=ZSURF_Variable;    break;
      case 2:  ZsurfMode=ZSURF_Calculated;  break;
      case 3:  ZsurfMode=ZSURF_WaveTheory;  break;
      default: sxml->ErrReadAtrib(xele,"mode",false,"Value is not valid.");
    }
    InputZbottom=sxml->ReadElementFloat(xele,"zbottom","value");
    if(ZsurfMode==ZSURF_Fixed || ZsurfMode==ZSURF_Calculated)InputZsurf=sxml->ReadElementFloat(xele,"zsurf","value");
    else if(ZsurfMode==ZSURF_Variable){
      const byte zlist=(sxml->ExistsElement(xele,"zsurftimes")? 1: 0);
      const byte zfile=(sxml->ExistsElement(xele,"zsurffile" )? 1: 0);
      if(zlist+zfile>1)sxml->ErrReadElement(xele,"zsurftimes/zsurffile",false,"Several definitions for zsurf were found.");
      if(zlist+zfile==0)sxml->ErrReadElement(xele,"zsurftimes/zsurffile",false,"No definitions for variable zsurf were found.");
      //-Loads list of time-values.
      TimeInputZsurf=new JLinearValue(1);
      TiXmlElement* xlis=xele->FirstChildElement("zsurftimes");
      if(xlis){
        const unsigned NTMIN=50;
        TimeInputZsurf->SetSize(NTMIN);
        TiXmlElement* elet=xlis->FirstChildElement("timevalue"); 
        while(elet){
          double t=sxml->GetAttributeDouble(elet,"time");
          double v=sxml->GetAttributeDouble(elet,"zsurf");
          TimeInputZsurf->AddTimeValue(t,v);
          elet=elet->NextSiblingElement("timevalue");
        }
      }
      else{
        TimeInputZsurf->LoadFile(dirdatafile+sxml->ReadElementStr(xele,"zsurffile","file"));
      }
      //-Select firt zsurf value.
      InputZsurf=(float)TimeInputZsurf->GetValue(0);
    }
    RemoveZsurf=sxml->ReadElementBool(xele,"remove","value",true,false);
    if(ZsurfMode==ZSURF_Calculated || ZsurfMode==ZSURF_Variable)SvVtkZsurf=sxml->ReadElementBool(xele,"savevtk","value",true,false);
  }
  else if(ZsurfMode!=ZSURF_WaveTheory)ZsurfMode=ZSURF_Undefined;

  //-Rhop configuration.
  xele=ele->FirstChildElement("imposerhop");
  if(xele){
    const unsigned mode=sxml->GetAttributeUint(xele,"mode",true);
    switch(mode){
      case 0:  RhopMode=MRHOP_Constant;      break;
      case 1:  RhopMode=MRHOP_Hydrostatic;   break;
      case 2:  RhopMode=MRHOP_Extrapolated;  break;
      default: sxml->ErrReadAtrib(xele,"mode",false,"Value is not valid.");
    }
    if(RhopMode==MRHOP_Hydrostatic && (InputZsurf==FLT_MAX || InputZbottom==FLT_MAX)){
      InputZsurf=sxml->ReadElementFloat(xele,"zsurf","value");
      InputZbottom=sxml->ReadElementFloat(xele,"zbottom","value");
    }
  }
  else{//-Default configuration for rhop.
    RhopMode=MRHOP_Constant;
  }

  //-Calcule initial number of new particles.
  if(ZsurfMode==ZSURF_Undefined)NpartInit=NptInit*Layers;
  else NpartInit=Points->GetCountZmax(InputZsurf)*Layers;

  //-Loads points in fluid domain to calculate zsurf.
  if(ZsurfMode==ZSURF_Calculated){
    PtzPos=new tfloat3[NptInit];
    const tdouble3 *ptpos=Points->GetPoints();
    const double dist=Dp/2 + GetDistPtzPos();//-It adds Dp/2 because the inlet limit is at +Dp/2.
    const tdouble3 dirmov=Direction*dist;
    for(unsigned p=0;p<NptInit;p++)PtzPos[p]=ToTFloat3(ptpos[p]+dirmov);
    #ifdef _WITHGPU
    if(!Cpu){
      fcuda::Malloc(&PtzPosg,NptInit);
      cudaMemcpy(PtzPosg,PtzPos,sizeof(float3)*NptInit,cudaMemcpyHostToDevice);
      fcuda::Malloc(&PtzAuxg,NptInit);
      PtzAux=new float[NptInit];
    }
    #endif
  }
}

//==============================================================================
/// Returns a byte with information about VelMode, VelProfile and RhopMode.
//==============================================================================
byte JSphInOutZone::GetConfigZone()const{
  const char met[]="GetConfigZone";
  if((VelProfile&PVEL_MASK )!=VelProfile)RunException(met,"VelProfile value is invalid to code using mask.");
  if((VelMode   &MVEL_MASK )!=VelMode)RunException(met,"VelMode value is invalid to code using mask.");
  if((RhopMode  &MRHOP_MASK)!=RhopMode)RunException(met,"RhopMode value is invalid to code using mask.");
  //if(byte(ZsurfMode) >3)RunException(met,"ZsurfMode value is invalid to code in 2 bits.");
  byte ret=byte(VelProfile);
  ret|=byte(VelMode);
  ret|=byte(RhopMode);
  if(ConvertFluid)ret|=byte(ConvertFluid_MASK);
  //-Checks coded configuration.
  TpVelProfile vprof=GetConfigVelProfile(ret);
  TpVelMode    vmode=GetConfigVelMode(ret);
  TpRhopMode   rmode=GetConfigRhopMode(ret);
  bool         convf=GetConfigConvertf(ret);
  //TpZsurfMode  zmode=GetConfigZsurfMode(ret);
  //if(vprof!=VelProfile || vmode!=VelMode || rmode!=RhopMode || zmode!=ZsurfMode)RunException(met,"Coded configuration is not right.");
  if(vprof!=VelProfile || vmode!=VelMode || rmode!=RhopMode || convf!=ConvertFluid)RunException(met,"Coded configuration is not right.");
  return(ret);
}

//==============================================================================
/// Calculates number of particles to resize memory.
//==============================================================================
unsigned JSphInOutZone::CalcResizeNp(double timestep,double timeinterval){
  const char met[]="CalcResizeNp";
  const float layerspersec=5;
  const unsigned newp=unsigned(timeinterval*layerspersec*NptInit);
  ////-Updates number of new fluid particles per second.
  //if(VelMode==MVEL_Variable){
  //  RevNewnpPerSec=true;
  //  UpdateInputVel(timestep);
  //}
  //if(VelMode==MVEL_Fixed || VelMode==MVEL_Variable)newp=NptInit+unsigned(NewnpPerSec*timeinterval);
  //else RunException(met,"Inflow velocity mode is unknown.");
  return(newp);
}

//==============================================================================
/// Loads positon of inlet/outlet points.
//==============================================================================
unsigned JSphInOutZone::LoadInletPoints(tdouble3 *pos){
  const tdouble3 *ptpos=Points->GetPoints();
  const tdouble3 dir=Direction*(Dp/2);
  for(unsigned cp=0;cp<NptInit;cp++)pos[cp]=ptpos[cp]+dir;
  return(NptInit);
}

//==============================================================================
/// Loads positon of inlet/outlet particles.
//==============================================================================
void JSphInOutZone::LoadInletParticles(tdouble3 *pos){
  const tdouble3 *ptpos=Points->GetPoints();
  unsigned p=0;
  for(unsigned layer=0;layer<Layers;layer++){
    const tdouble3 dir=Direction*(-Dp*layer);
    for(unsigned cp=0;cp<NptInit;cp++)if(ZsurfMode==ZSURF_Undefined || float(ptpos[cp].z)<=InputZsurf){
      pos[p]=ptpos[cp]+dir;
      p++;
    }
  }
  //Log->Printf(" LoadInletParticles--> p:%u  NptInit:%u  Layers:%u",p,NptInit,Layers);
  Points->ResetPoints();//-Frees memory of points.
}

//==============================================================================
/// Returns velocity according profile configuration.
//==============================================================================
float JSphInOutZone::CalcVel(JSphInOutZone::TpVelProfile vprof,const tfloat4 &vdata,double posz){
  float vel=0;
  if(vprof==JSphInOutZone::PVEL_Constant)vel=vdata.x;
  else if(vprof==JSphInOutZone::PVEL_Linear){
    const float m=vdata.x;
    const float b=vdata.y;
    vel=m*float(posz)+b;
  }
  else if(vprof==JSphInOutZone::PVEL_Parabolic){
    const float a=vdata.x;
    const float b=vdata.y;
    const float c=vdata.z;
    vel=a*float(posz)*float(posz)+b*float(posz)+c;
  }
  return(vel);
}

//==============================================================================
/// Updates velocity coefficients for imposed velocity according timestep. 
/// Returns true when the data was changed.
//==============================================================================
bool JSphInOutZone::UpdateVelData(double timestep,bool full,tfloat4 &vel0,tfloat4 &vel1){
  const char met[]="UpdateVelData";
  bool modified=full;
  if(VelMode==MVEL_Fixed){
    if(full){
      if(VelProfile==PVEL_Constant){
        vel0=TFloat4(InputVel,0,0,0);  vel1=TFloat4(0);
        //const float v=InputVel;
      }
      else if(VelProfile==PVEL_Linear){
        const float m=(InputVel2-InputVel)/(InputVelPosz2-InputVelPosz);
        const float b=InputVel-m*InputVelPosz;
        vel0=TFloat4(m,b,0,0);  vel1=TFloat4(0);
        //const float v=m*float(vecpos[p].z)+b;
        //if(SaveVelProfile && Npt){
        //  SaveVelProfile=false;
        //  JSaveCsv sv(Log->GetDirOut()+fun::PrintStr("Inlet_%d_VelProfileLinear.csv",IdZone),true);
        //  sv.AddHead("time;z;vel");
        //  const double y0=vecpos[0].y;
        //  for(unsigned p=0;p<Npt;p++)if(y0==vecpos[p].y){
        //    sv.AddValuesf("%g;%g;%f",timestep,vecpos[p].z,vecvel[p]);
        //    sv.AddEndl();
        //  }
        //}
      }
      else if(VelProfile==PVEL_Parabolic){
        const tmatrix3f inv=fmath::InverseMatrix3x3(TMatrix3f(InputVelPosz*InputVelPosz,InputVelPosz,1,InputVelPosz2*InputVelPosz2,InputVelPosz2,1,InputVelPosz3*InputVelPosz3,InputVelPosz3,1));
        const float a=inv.a11*InputVel+inv.a12*InputVel2+inv.a13*InputVel3;
        const float b=inv.a21*InputVel+inv.a22*InputVel2+inv.a23*InputVel3;
        const float c=inv.a31*InputVel+inv.a32*InputVel2+inv.a33*InputVel3;
        vel0=TFloat4(a,b,c,0);  vel1=TFloat4(0);
        //const float v=a*float(vecpos[p].z)*float(vecpos[p].z)+b*float(vecpos[p].z)+c;
        //if(SaveVelProfile && Npt){
        //  SaveVelProfile=false;
        //  JSaveCsv sv(Log->GetDirOut()+fun::PrintStr("Inlet_%d_VelProfileParabolic.csv",IdZone),true);
        //  sv.AddHead("time;z;vel");
        //  const double y0=vecpos[0].y;
        //  for(unsigned p=0;p<Npt;p++)if(y0==vecpos[p].y){
        //    sv.AddValuesf("%g;%g;%f",timestep,vecpos[p].z,vecvel[p]);
        //    sv.AddEndl();
        //  }
        //}
      }
      else RunException(met,"Inlet/outlet velocity profile is unknown.");
    }
  }
  else if(VelMode==MVEL_Variable){
    TimeInputVelData->FindTime(timestep);
    unsigned idx0=TimeVelIdx0,idx1=TimeVelIdx1;
    TimeVelIdx0=TimeInputVelData->GetPos();
    TimeVelIdx1=TimeInputVelData->GetPosNext();
    if(full || idx0!=TimeVelIdx0 || idx1!=TimeVelIdx1){
      modified=true;
      const float t =(float)TimeInputVelData->GetTimeByIdx(TimeVelIdx0);
      const float t2=(float)TimeInputVelData->GetTimeByIdx(TimeVelIdx1);
      if(VelProfile==PVEL_Constant){
        //TimeInputVelData->AddTimeValue(t,v);
        vel0=TFloat4((float)TimeInputVelData->GetValueByIdx(TimeVelIdx0),0,0,t);
        vel1=TFloat4((float)TimeInputVelData->GetValueByIdx(TimeVelIdx1),0,0,t2);
      }
      else if(VelProfile==PVEL_Linear){
        //TimeInputVelData->AddTimeValue(t,v,v2,z,z2);
        for(unsigned cc=0;cc<=1;cc++){
          const unsigned idx=(!cc? TimeVelIdx0: TimeVelIdx1);
          const float v =(float)TimeInputVelData->GetValueByIdx(idx,0);
          const float v2=(float)TimeInputVelData->GetValueByIdx(idx,1);
          const float z =(float)TimeInputVelData->GetValueByIdx(idx,2);
          const float z2=(float)TimeInputVelData->GetValueByIdx(idx,3);
          const float m=(v2-v)/(z2-z);
          const float b=v-m*z;
          if(!cc)vel0=TFloat4(m,b,0,t);
          else   vel1=TFloat4(m,b,0,t2);
        }
      }
      else if(VelProfile==PVEL_Parabolic){
        //TimeInputVelData->AddTimeValue(t,v,v2,v3,z,z2,z3);
        for(unsigned cc=0;cc<=1;cc++){
          const unsigned idx=(!cc? TimeVelIdx0: TimeVelIdx1);
          const float v =(float)TimeInputVelData->GetValueByIdx(idx,0);
          const float v2=(float)TimeInputVelData->GetValueByIdx(idx,1);
          const float v3=(float)TimeInputVelData->GetValueByIdx(idx,2);
          const float z =(float)TimeInputVelData->GetValueByIdx(idx,3);
          const float z2=(float)TimeInputVelData->GetValueByIdx(idx,4);
          const float z3=(float)TimeInputVelData->GetValueByIdx(idx,5);
          const tmatrix3f inv=fmath::InverseMatrix3x3(TMatrix3f(z*z,z,1,z2*z2,z2,1,z3*z3,z3,1));
          const float a=inv.a11*v+inv.a12*v2+inv.a13*v3;
          const float b=inv.a21*v+inv.a22*v2+inv.a23*v3;
          const float c=inv.a31*v+inv.a32*v2+inv.a33*v3;
          if(!cc)vel0=TFloat4(a,b,c,t);
          else   vel1=TFloat4(a,b,c,t2);
        }
      }
      else RunException(met,"Inlet/outlet velocity profile is unknown.");
    }
  }
  else if(VelMode!=MVEL_Extrapolated && VelMode!=MVEL_Interpolated)RunException(met,"Inlet/outlet velocity mode is unknown.");
  return(modified);
}

//==============================================================================
/// Updates zsurf according timestep. 
/// Returns true when the data was changed.
//==============================================================================
bool JSphInOutZone::UpdateZsurf(double timestep,bool full,float &zsurf){
  const char met[]="UpdateZsurf";
  bool modified=full;
  if(ZsurfMode==ZSURF_Undefined || ZsurfMode==ZSURF_Fixed){
    if(full)zsurf=InputZsurf;
  }
  else if(ZsurfMode==ZSURF_Variable){
    const float zsurf1=(float)TimeInputZsurf->GetValue(timestep);
    //Log->Printf(" JSphInOutZone::UpdateZsurf---> zsurf1:%f  time:%f",zsurf1,timestep);
    modified|=(InputZsurf!=zsurf1);
    if(modified)zsurf=InputZsurf=zsurf1;
  }
  else if(ZsurfMode==ZSURF_Calculated){
    modified|=(InputZsurf!=zsurf);
    if(modified)zsurf=InputZsurf;
  }
  else RunException(met,"Inlet/outlet zsurf mode is unknown.");
  return(modified);
}

//==============================================================================
/// Indicates if position is inside inlet zone using BoxLimitMin/Max.
//==============================================================================
bool JSphInOutZone::InZoneBox(const tfloat3 &ps)const{
  return(BoxLimitMin.x<=ps.x && ps.x<=BoxLimitMax.x && BoxLimitMin.y<=ps.y && ps.y<=BoxLimitMax.y && BoxLimitMin.z<=ps.z && ps.z<=BoxLimitMax.z);
}

//==============================================================================
/// Indicates if position is inside inlet zone, using plane and BoxLimitMin/Max.
//==============================================================================
bool JSphInOutZone::InZone(bool useboxlimit,const tfloat3 &ps)const{
  return((!useboxlimit || InZoneBox(ps)) && fgeo::PlanePoint(Plane,ps)<0);
}

//==============================================================================
/// Saves grid nodes in VTK file.
//==============================================================================
void JSphInOutZone::SaveVtkVelGrid(std::string filename)const{
  if(InputVelGrid)InputVelGrid->SaveDataVtk(filename,0);
}


//==============================================================================
/// Returns true when zone is MVEL_Variable, PVEL_Constant and ZSURF_Variable.
//==============================================================================
bool JSphInOutZone::IsVariableInput()const{
  return(VelMode==MVEL_Variable && VelProfile==PVEL_Constant && ZsurfMode==ZSURF_Variable);
}

//==============================================================================
/// Activate or deactivate use of external data (ExternalVarInput).
//==============================================================================
void JSphInOutZone::SetExternalVarInput(bool active){
  if(!IsVariableInput())RunException("SetExternalVarInput","Input configuration is invalid.");
  if(!ExternalVarInput && active)InitExtVarInput();
  ExternalVarInput=active;
}

//==============================================================================
/// Initialisation of TimeInputVelData and TimeInputZsurf.
//==============================================================================
void JSphInOutZone::InitExtVarInput(){
  if(!IsVariableInput())RunException("InitExtVarInput","Input configuration is invalid.");
  TimeInputVelData->Reset();
  TimeInputVelData->AddTimeValue(0,0);
  TimeInputVelData->AddTimeValue(DBL_MAX,0);
  TimeInputZsurf->Reset();
  TimeInputZsurf->AddTimeValue(0,0);
  TimeInputZsurf->AddTimeValue(DBL_MAX,0);
}

//==============================================================================
/// Returns velocity configuration in TimeInputVelData.
/// Returns TFloat4(time1,vel1,time2,vel2).
//==============================================================================
tfloat4 JSphInOutZone::GetExtVarVelocity1()const{
  if(VelMode!=MVEL_Variable || VelProfile!=PVEL_Constant)RunException("GetVariableVelocity1","Velocity mode or profile is invalid.");
  const unsigned nt=TimeInputVelData->GetCount();
  unsigned idx=0;
  if(nt>2)idx=TimeInputVelData->GetPos();
  const float t1=(idx<nt?   float(TimeInputVelData->GetTimeByIdx (idx))    : 0);
  const float v1=(idx<nt?   float(TimeInputVelData->GetValueByIdx(idx,0))  : 0);
  const float t2=(idx+1<nt? float(TimeInputVelData->GetTimeByIdx (idx+1))  : t1);
  const float v2=(idx+1<nt? float(TimeInputVelData->GetValueByIdx(idx+1,0)): v1);
  return(TFloat4(t1,v1,t2,v2));
}

//==============================================================================
/// Returns zsurf configuration in TimeInputZsurf.
/// Returns TFloat4(time1,z1,time2,z2).
//==============================================================================
tfloat4 JSphInOutZone::GetExtVarZsurf()const{
  if(ZsurfMode!=ZSURF_Variable)RunException("GetVariableZsurf","Zsurf mode is not Variable.");
  const unsigned nt=TimeInputZsurf->GetCount();
  unsigned idx=0;
  if(nt>2)idx=TimeInputZsurf->GetPos();
  const float t1=(idx<nt?   float(TimeInputZsurf->GetTimeByIdx (idx))    : 0);
  const float v1=(idx<nt?   float(TimeInputZsurf->GetValueByIdx(idx,0))  : 0);
  const float t2=(idx+1<nt? float(TimeInputZsurf->GetTimeByIdx (idx+1))  : t1);
  const float v2=(idx+1<nt? float(TimeInputZsurf->GetValueByIdx(idx+1,0)): v1);
  return(TFloat4(t1,v1,t2,v2));
}

//==============================================================================
/// Modify velocity configuration in TimeInputVelData.
//==============================================================================
void JSphInOutZone::SetExtVarVelocity1(double t1,double v1,double t2,double v2){
  if(!ExternalVarInput)RunException("SetVarVelocity1","ExternalVarInput is not activated.");
  TimeInputVelData->SetTimeValue(0,t1,v1);
  TimeInputVelData->SetTimeValue(1,t2,v2);
}

//==============================================================================
/// Modify zsurf configuration in TimeInputZsurf.
//==============================================================================
void JSphInOutZone::SetExtVarZsurf(double t1,double v1,double t2,double v2){
  if(!ExternalVarInput)RunException("SetExtVarZsurf","ExternalVarInput is not activated.");
  TimeInputZsurf->SetTimeValue(0,t1,v1);
  TimeInputZsurf->SetTimeValue(1,t2,v2);
}


//##############################################################################
//# JSphInOut
//##############################################################################
//==============================================================================
/// Constructor.
//==============================================================================
JSphInOut::JSphInOut(bool cpu,JLog2 *log,std::string xmlfile,JXml *sxml,std::string xmlpath,const std::string &dirdatafile)
  :Cpu(cpu),Log(log),XmlFile(xmlfile),XmlPath(xmlpath),DirDataFile(dirdatafile)
{
  ClassName="JSphInOut";
  Planes=NULL;
  CfgZone=NULL;  Width=NULL;  DirData=NULL;  VelData=NULL;  Zbottom=NULL; Zsurf=NULL;
  PtZone=NULL;  PtPos=NULL;  PtAuxDist=NULL;
  #ifdef _WITHGPU
    Planesg=NULL; BoxLimitg=NULL; CfgZoneg=NULL; Widthg=NULL; DirDatag=NULL; Zsurfg=NULL;
    PtZoneg=NULL; PtPosxyg=NULL; PtPoszg=NULL; PtAuxDistg=NULL;
  #endif
  Reset();
  //-Loads basic configuration.
  LoadXmlInit(sxml,xmlpath);
}

//==============================================================================
/// Destructor.
//==============================================================================
JSphInOut::~JSphInOut(){
  DestructorActive=true;
  Reset();
}

//==============================================================================
/// Initialisation of variables.
//==============================================================================
void JSphInOut::Reset(){

  Stable=Simulate2D=false;
  Simulate2DPosY=0;
  PeriActive=0;
  RhopZero=CteB=Gamma=GravityZ=CoefHydro=0;
  Dp=0;
  MapRealPosMin=MapRealPosMax=TDouble3(0);
  CodeNewPart=0;

  ReuseIds=false;
  ResizeTime=0;
  DetermLimit=0;
  ExtrapolateMode=0;

  UseBoxLimit=true;
  FreeCentre=TFloat3(FLT_MAX);
  FreeLimitMin=TFloat3(-FLT_MAX);
  FreeLimitMax=TFloat3(FLT_MAX);

  NewNpTotal=0;
  NewNpPart=0;

  VariableVel=false;
  VariableZsurf=false;
  CalculatedZsurf=false;
  ExtrapolatedData=NoExtrapolatedData=false;
  InterpolatedVel=false;
  for(int c=0;c<List.size();c++)delete List[c];
  List.clear();
  FreeMemory();

  UseRefilling=false;
  FreePtMemory();
}

//==============================================================================
/// Loads initial conditions of XML object.
//==============================================================================
void JSphInOut::LoadXmlInit(JXml *sxml,const std::string &place){
  const char met[]="LoadXmlInit";
  TiXmlNode* node=sxml->GetNode(place,false);
  if(!node)RunException("LoadXmlInit",std::string("Cannot find the element \'")+place+"\'.");
  TiXmlElement* ele=node->ToElement();
  //-Loads general configuration.
  ReuseIds=sxml->GetAttributeBool(ele,"reuseids",true,false);
  ResizeTime=sxml->GetAttributeDouble(ele,"resizetime",true);
  //-Loads value userefilling.
  const unsigned nrefill=(sxml->ExistsAttribute(ele,"userefilling")? 1: 0)+sxml->CountElements(ele,"userefilling");
  if(nrefill>1)sxml->ErrReadElement(ele,"userefilling",false,"Several definitions for this value.");
  if(sxml->ExistsAttribute(ele,"userefilling"))UseRefilling=sxml->GetAttributeBool(ele,"userefilling",true,false);
  else UseRefilling=sxml->ReadElementBool(ele,"userefilling","value",true,false);
  //-Loads value determlimit.
  if(sxml->CountElements(ele,"determlimit")>1)sxml->ErrReadElement(ele,"determlimit",false,"Several definitions for this value.");
  DetermLimit=sxml->ReadElementFloat(ele,"determlimit","value",true,1e+3f);
  //-Loads ExtrapolateMode.
  ExtrapolateMode=sxml->ReadElementInt(ele,"extrapolatemode","value",true,1);
  if(ExtrapolateMode>3)ExtrapolateMode=3;
  if(ExtrapolateMode<1)ExtrapolateMode=1;
  if(ExtrapolateMode<2 && Cpu)ExtrapolateMode=2;
  //-Loads UseBoxLimit.
  UseBoxLimit=sxml->ReadElementBool(ele,"useboxlimit","value",true,true);
  {
    TiXmlElement* ele2=ele->FirstChildElement("useboxlimit"); 
    if(ele2 && sxml->ExistsElement(ele2,"freecentre"))FreeCentre=sxml->ReadElementFloat3(ele2,"freecentre");
    else FreeCentre=TFloat3(FLT_MAX);
  }
  //-Loads MkFluidList.
  MkFluidList.clear();
  TiXmlElement* ele2=ele->FirstChildElement("inoutzone"); 
  while(ele2){
    TiXmlElement* zone=ele2->FirstChildElement("zone2d");
    if(!zone)zone=ele2->FirstChildElement("zone3d");
    if(zone){
      const unsigned mkfluid=sxml->ReadElementUnsigned(zone,"particles","mkfluid",true,UINT_MAX);
      if(mkfluid!=UINT_MAX){
        unsigned c=0;
        for(;c<unsigned(MkFluidList.size()) && mkfluid!=MkFluidList[c];c++);
        if(c<unsigned(MkFluidList.size()))RunException(met,fun::PrintStr("Mkfluid=%u is used in several <inoutzone> definitions.",mkfluid));
        MkFluidList.push_back(mkfluid);
      }
    }
    ele2=ele2->NextSiblingElement("inoutzone");
  }
}

//==============================================================================
/// Loads data of a file in XML format.
//==============================================================================
void JSphInOut::LoadFileXml(const std::string &file,const std::string &path
  ,const JSphPartsInit *partsdata)
{
  JXml jxml;
  jxml.LoadFile(file);
  LoadXml(&jxml,path,partsdata);
}

//==============================================================================
/// Loads initial conditions of XML object.
//==============================================================================
void JSphInOut::LoadXml(JXml *sxml,const std::string &place,const JSphPartsInit *partsdata){
  TiXmlNode* node=sxml->GetNode(place,false);
  if(!node)RunException("LoadXml",std::string("Cannot find the element \'")+place+"\'.");
  ReadXml(sxml,node->ToElement(),partsdata);
}

//==============================================================================
/// Reads list of initial conditions in the XML node.
//==============================================================================
void JSphInOut::ReadXml(JXml *sxml,TiXmlElement* lis,const JSphPartsInit *partsdata){
  const char met[]="ReadXml";
  //-Loads inflow elements.
  const unsigned idmax=CODE_MASKTYPEVALUE-CODE_TYPE_FLUID_INOUT;
  if(idmax!=MaxZones-1)RunException(met,"Maximum number of inlet/outlet zones is invalid.");
  TiXmlElement* ele=lis->FirstChildElement("inoutzone"); 
  while(ele){
    const unsigned id=GetCount();
    if(id>idmax)RunException(met,"Maximum number of inlet/outlet zones has been reached.");
    JSphInOutZone* iet=new JSphInOutZone(Cpu,Log,id,Simulate2D,Simulate2DPosY,Dp,MapRealPosMin,MapRealPosMax,sxml,ele,DirDataFile,partsdata);
    List.push_back(iet);
    ele=ele->NextSiblingElement("inoutzone");
  }
}

//==============================================================================
/// Allocates memory for inlet/outlet configurations.
//==============================================================================
void JSphInOut::AllocateMemory(unsigned listsize){
  const char met[]="AllocateMemory";
  ListSize=listsize;
  try{
    Planes   =new tplane3f[ListSize];
    CfgZone  =new byte    [ListSize];
    Width    =new float   [ListSize];
    DirData  =new tfloat3 [ListSize];
    VelData  =new tfloat4 [ListSize*2];
    Zbottom  =new float   [ListSize];
    Zsurf    =new float   [ListSize];
  }
  catch(const std::bad_alloc){
    RunException(met,"Could not allocate the requested memory.");
  }
  #ifdef _WITHGPU
    if(!Cpu)AllocateMemoryGpu(ListSize);
  #endif
}

//==============================================================================
/// Frees allocated memory.
//==============================================================================
void JSphInOut::FreeMemory(){
  ListSize=0;
  delete[] Planes;    Planes=NULL;
  delete[] CfgZone;   CfgZone=NULL;
  delete[] Width;     Width=NULL;
  delete[] DirData;   DirData=NULL;
  delete[] VelData;   VelData=NULL;
  delete[] Zbottom;   Zbottom=NULL;
  delete[] Zsurf;     Zsurf=NULL;
  #ifdef _WITHGPU
    if(!Cpu)FreeMemoryGpu();
  #endif
}

//==============================================================================
/// Allocates memory for reference points.
//==============================================================================
void JSphInOut::AllocatePtMemory(unsigned ptcount){
  const char met[]="AllocatePtMemory";
  PtCount=ptcount;
  try{
    PtZone   =new byte    [ptcount];
    PtPos    =new tdouble3[ptcount];
    PtAuxDist=new float   [ptcount];
  }
  catch(const std::bad_alloc){
    RunException(met,"Could not allocate the requested memory.");
  }
  #ifdef _WITHGPU
    if(!Cpu)AllocatePtMemoryGpu(PtCount);
  #endif
}

//==============================================================================
/// Frees allocated memory for reference points and auxiliary memory.
//==============================================================================
void JSphInOut::FreePtMemory(){
  PtCount=0;
  delete[] PtZone;    PtZone=NULL;
  delete[] PtPos;     PtPos=NULL;
  delete[] PtAuxDist; PtAuxDist=NULL;
  #ifdef _WITHGPU
    if(!Cpu)FreePtMemoryGpu();
  #endif
}

#ifdef _WITHGPU
//==============================================================================
/// Allocates memory for reference points on GPU.
//==============================================================================
void JSphInOut::AllocatePtMemoryGpu(unsigned ptcount){
  fcuda::Malloc(&PtZoneg,ptcount);
  fcuda::Malloc(&PtPosxyg,ptcount);
  fcuda::Malloc(&PtPoszg,ptcount);
  fcuda::Malloc(&PtAuxDistg,ptcount);
}

//==============================================================================
/// Frees allocated memory for reference points and auxiliary memory on GPU.
//==============================================================================
void JSphInOut::FreePtMemoryGpu(){
  if(PtZoneg)   cudaFree(PtZoneg);    PtZoneg=NULL;
  if(PtPosxyg)  cudaFree(PtPosxyg);   PtPosxyg=NULL;
  if(PtPoszg)   cudaFree(PtPoszg);    PtPoszg=NULL;
  if(PtAuxDistg)cudaFree(PtAuxDistg); PtAuxDistg=NULL;
}

//==============================================================================
/// Allocates memory on GPU for inlet/outlet configurations.
//==============================================================================
void JSphInOut::AllocateMemoryGpu(unsigned listsize){
  const char met[]="AllocateMemoryGpu";
  try{
    fcuda::Malloc(&Planesg  ,ListSize);
    fcuda::Malloc(&BoxLimitg,ListSize*3);
    fcuda::Malloc(&CfgZoneg ,ListSize);
    fcuda::Malloc(&Widthg   ,ListSize);
    fcuda::Malloc(&DirDatag ,ListSize);
    fcuda::Malloc(&Zsurfg   ,ListSize);
  }
  catch(const std::bad_alloc){
    RunException(met,"Could not allocate the requested memory.");
  }
}

//==============================================================================
/// Frees allocated memory on GPU.
//==============================================================================
void JSphInOut::FreeMemoryGpu(){
  if(Planesg)  cudaFree(Planesg);   Planesg=NULL;
  if(BoxLimitg)cudaFree(BoxLimitg); BoxLimitg=NULL;
  if(CfgZoneg) cudaFree(CfgZoneg);  CfgZoneg=NULL;
  if(Widthg)   cudaFree(Widthg);    Widthg=NULL;
  if(DirDatag) cudaFree(DirDatag);  DirDatag=NULL;
  if(Zsurfg)   cudaFree(Zsurfg);    Zsurfg=NULL;
}
#endif


//==============================================================================
/// Saves domain zones in VTK file.
//==============================================================================
void JSphInOut::ComputeFreeDomain(){
  const char met[]="ComputeFreeDomain";
  //-Recalculates FreeCentre starting from domain simulation.
  if(FreeCentre==TFloat3(FLT_MAX))FreeCentre=ToTFloat3((MapRealPosMax+MapRealPosMin)/2);
  //Log->Printf("----> FreeCentre:(%g,%g,%g)",FreeCentre.x,FreeCentre.y,FreeCentre.z);
  //-Calculates domain starting from FreeCentre for each axis.
  tfloat3 pmin=ToTFloat3(MapRealPosMin),pmax=ToTFloat3(MapRealPosMax);
  const unsigned nzone=GetCount();
  tfloat3 *zolimit=new tfloat3[nzone];
  byte *sel=new byte[nzone];
  tfloat3 *dmin=new tfloat3[nzone+1];
  tfloat3 *dmax=new tfloat3[nzone+1];
  for(unsigned ci=0;ci<nzone;ci++){ 
    sel[ci]=0;
    const tfloat3 boxmin=List[ci]->GetBoxLimitMin();
    const tfloat3 boxmax=List[ci]->GetBoxLimitMax();
    zolimit[ci].x=(FreeCentre.x<=boxmin.x? boxmin.x: (FreeCentre.x>=boxmax.x? boxmax.x: FLT_MAX));
    zolimit[ci].y=(FreeCentre.y<=boxmin.y? boxmin.y: (FreeCentre.y>=boxmax.y? boxmax.y: FLT_MAX));
    zolimit[ci].z=(FreeCentre.z<=boxmin.z? boxmin.z: (FreeCentre.z>=boxmax.z? boxmax.z: FLT_MAX));
    if(zolimit[ci].x==FLT_MAX && zolimit[ci].z==FLT_MAX && (Simulate2D || zolimit[ci].y==FLT_MAX))
      RunException(met,fun::PrintStr("FreeCentre position (%g,%g,%g) is within the inout zone %d. FreeCentre must be changed in XML file.",FreeCentre.x,FreeCentre.y,FreeCentre.z,ci));
  }
  //-Look for the best solution for FreeLimitMin/Max.
  const byte nsel=(Simulate2D? 2: 3);
  float bestsize=-FLT_MAX;
  tfloat3 bestmin,bestmax;
  sel[0]=0;
  dmin[0]=pmin;
  dmax[0]=pmax;
  unsigned ci=0;
  bool run=true;
  //unsigned cd=0;
  while(run){
    if(sel[ci]<nsel){
      sel[ci]++;
      pmin=dmin[ci]; pmax=dmax[ci];
      bool ok=false;
      if(sel[ci]==1 && zolimit[ci].x!=FLT_MAX){//-Adjust in X.
        if(zolimit[ci].x<=FreeCentre.x)pmin.x=max(pmin.x,zolimit[ci].x);
        else                           pmax.x=min(pmax.x,zolimit[ci].x);
        ok=true;
      }
      if(sel[ci]==2 && zolimit[ci].z!=FLT_MAX){//-Adjust in Z.
        if(zolimit[ci].z<=FreeCentre.z)pmin.z=max(pmin.z,zolimit[ci].z);
        else                           pmax.z=min(pmax.z,zolimit[ci].z);
        ok=true;
      }
      if(sel[ci]==3 && zolimit[ci].y!=FLT_MAX){//-Adjust in Y.
        if(zolimit[ci].y<=FreeCentre.y)pmin.y=max(pmin.y,zolimit[ci].y);
        else                           pmax.y=min(pmax.y,zolimit[ci].y);
        ok=true;
      }
      if(ok){
        const tfloat3 ss=pmax-pmin;
        const float size=(Simulate2D? ss.x*ss.z: ss.x*ss.y*ss.z);
        if(size>bestsize){
          if(ci+1==nzone){//-Last zone was used.
            //if(1){
            //  string tx;
            //  for(unsigned cc=0;cc<nzone;cc++)tx=tx+fun::PrintStr("-[%u]",sel[cc]);
            //  Log->Printf("-----> %u >---%s: %f",cd,tx.c_str(),size);cd++;
            //  std::vector<JFormatFiles2::StShapeData> shapes;
            //  shapes.push_back(JFormatFiles2::DefineShape_Box(pmin,pmax-pmin,cd,0));
            //  JFormatFiles2::SaveVtkShapes(Log->GetDirOut()+fun::FileNameSec("CfgInOut_DG_FreeDomain.vtk",cd),"","",shapes);
            //}
            bestsize=size;
            bestmin=pmin; bestmax=pmax;
          }
          else{//-Use next zone.
            ci++;
            sel[ci]=0;
            dmin[ci]=pmin; dmax[ci]=pmax;
          }
        }
      }
    }
    else{
      sel[ci]=0;
      if(ci>0)ci--;    //-Go to previous zone
      else run=false;  //-or finish.
    }
  }
  //-Saves best solution.
  FreeLimitMin=bestmin;
  FreeLimitMax=bestmax;
  //SaveVtkDomains();
  //RunException(met,"Stop");
}

//==============================================================================
/// Saves domain zones in VTK file.
//==============================================================================
void JSphInOut::SaveVtkDomains(){
  const char met[]="SaveVtkDomains";
  //-InOut real domains.
  {
    std::vector<JFormatFiles2::StShapeData> shapes;
    for(unsigned ci=0;ci<GetCount();ci++){
      const JSphInOutZone *izone=List[ci];
      const tdouble3* ptdom=izone->GetPtDomain();
      if(Simulate2D){
        shapes.push_back(JFormatFiles2::DefineShape_Quad(ptdom[0],ptdom[1],ptdom[2],ptdom[3],ci,0));
      }
      else{
        shapes.push_back(JFormatFiles2::DefineShape_Box(ptdom[0],ptdom[1],ptdom[2],ptdom[3],ptdom[4],ptdom[5],ptdom[6],ptdom[7],ci,0));
      }
      shapes.push_back(JFormatFiles2::DefineShape_Line(ptdom[8],ptdom[9],ci,0)); //-Normal line.
    }
    const string filevtk=AppInfo.GetDirOut()+"CfgInOut_DomainReal.vtk";
    JFormatFiles2::SaveVtkShapes(filevtk,"izone","",shapes);
    Log->AddFileInfo(filevtk,"Saves real domain of InOut configurations.");
  }
  //-InOut box domains.
  {
    std::vector<JFormatFiles2::StShapeData> shapes;
    for(unsigned ci=0;ci<GetCount();ci++){
      tfloat3 boxmin=List[ci]->GetBoxLimitMin();
      tfloat3 boxmax=List[ci]->GetBoxLimitMax();
      if(Simulate2D){
        boxmin.y=boxmax.y=float(Simulate2DPosY);
        const tfloat3 pt1=TFloat3(boxmax.x,boxmin.y,boxmin.z);
        const tfloat3 pt2=TFloat3(boxmin.x,boxmax.y,boxmax.z);
        shapes.push_back(JFormatFiles2::DefineShape_Quad(boxmin,pt1,boxmax,pt2,ci,0));
      }
      else shapes.push_back(JFormatFiles2::DefineShape_Box(boxmin,boxmax-boxmin,ci,0));
    }
    //-Draws FreeCentre.
    {
      tfloat3 pc0=FreeCentre-TFloat3(float(Dp/2));
      tfloat3 pc2=FreeCentre+TFloat3(float(Dp/2));
      tfloat3 pc1=TFloat3(pc2.x,pc0.y,pc0.z);
      tfloat3 pc3=TFloat3(pc0.x,pc2.y,pc2.z);
      if(Simulate2D){
        pc0.y=pc1.y=pc2.y=pc3.y=float(Simulate2DPosY);
        shapes.push_back(JFormatFiles2::DefineShape_Quad(pc0,pc1,pc2,pc3,GetCount(),0));
      }
      else shapes.push_back(JFormatFiles2::DefineShape_Box(pc0,pc2-pc0,GetCount(),0));
    }
    //-Draws FreeLimitMin/Max.
    {
      tfloat3 pc0=MaxValues(FreeLimitMin,ToTFloat3(MapRealPosMin));
      tfloat3 pc2=MinValues(FreeLimitMax,ToTFloat3(MapRealPosMax));
      tfloat3 pc1=TFloat3(pc2.x,pc0.y,pc0.z);
      tfloat3 pc3=TFloat3(pc0.x,pc2.y,pc2.z);
      if(Simulate2D){
        pc0.y=pc1.y=pc2.y=pc3.y=float(Simulate2DPosY);
        shapes.push_back(JFormatFiles2::DefineShape_Quad(pc0,pc1,pc2,pc3,GetCount(),0));
      }
      else shapes.push_back(JFormatFiles2::DefineShape_Box(pc0,pc2-pc0,GetCount(),0));
    }
    const string filevtk=AppInfo.GetDirOut()+"CfgInOut_DomainBox.vtk";
    JFormatFiles2::SaveVtkShapes(filevtk,"izone","",shapes);
    Log->AddFileInfo(filevtk,"Saves box domain of InOut configurations.");
  }
}

//==============================================================================
/// Saves VTK of InputVelGrid nodes.
//==============================================================================
void JSphInOut::SaveVtkVelGrid(){
  const char met[]="SaveVtkVelGrid";
  for(unsigned ci=0;ci<GetCount();ci++)if(List[ci]->GetInterpolatedVel()){
    const string filevtk=AppInfo.GetDirOut()+fun::PrintStr("CfgInOut_VelGrid_i%d.vtk",ci);
    List[ci]->SaveVtkVelGrid(filevtk);
    Log->AddFileInfo(filevtk,"Saves VTK file with InputVelGrid nodes (by JSphInOut).");
  }
}

//==============================================================================
/// Configures basic parameter of the simulation and prepares execution and 
/// returns number of initial inlet particles.
//==============================================================================
unsigned JSphInOut::Config(double timestep,bool stable,bool simulate2d,double simulate2dposy
  ,byte periactive,float rhopzero,float cteb,float gamma,tfloat3 gravity,double dp
  ,tdouble3 posmin,tdouble3 posmax,typecode codenewpart,const JSphPartsInit *partsdata)
{
  const char met[]="Config";
  Stable=stable;
  Simulate2D=simulate2d;
  Simulate2DPosY=simulate2dposy;
  PeriActive=periactive;
  RhopZero=rhopzero;
  CteB=cteb;
  Gamma=gamma;
  GravityZ=gravity.z;
  if(gravity.x!=0 || gravity.y!=0)Log->PrintfWarning("Only gravity in Z (0,0,%g) is used in inlet/outlet code (e.g.: hydrostatic density or water elevation calculation).",GravityZ);
  CoefHydro=RhopZero*(-GravityZ)/CteB;
  Dp=dp;
  MapRealPosMin=posmin; MapRealPosMax=posmax;
  CodeNewPart=codenewpart;
  //-Loads Xml configuration.
  LoadFileXml(XmlFile,XmlPath,partsdata);
  
  //-Calculates and saves domain zones.
  ComputeFreeDomain();
  SaveVtkDomains();
  //-Saves VTK of InputVelGrid nodes.
  SaveVtkVelGrid();

  //-Allocates memory for inlet/outlet configurations.
  AllocateMemory(GetCount());
  //-Prepares data for inlet/outlet configurations.
  for(unsigned ci=0;ci<ListSize;ci++){
    Planes [ci]=List[ci]->GetPlane();
    CfgZone[ci]=List[ci]->GetConfigZone();
    Width  [ci]=float(Dp*List[ci]->GetLayers());
    DirData[ci]=ToTFloat3(List[ci]->GetDirection());
    Zbottom[ci]=List[ci]->GetInputZbottom();
  }
  UpdateVelData(timestep,true);
  UpdateZsurf(timestep,true);

  #ifdef _WITHGPU
    if(!Cpu){
      //-Copies data to GPU memory.
      cudaMemcpy(Planesg ,Planes ,sizeof(float4)*ListSize,cudaMemcpyHostToDevice);
      cudaMemcpy(CfgZoneg,CfgZone,sizeof(byte)  *ListSize,cudaMemcpyHostToDevice);
      cudaMemcpy(Widthg  ,Width  ,sizeof(float) *ListSize,cudaMemcpyHostToDevice);
      cudaMemcpy(DirDatag,DirData,sizeof(float3)*ListSize,cudaMemcpyHostToDevice);
      //cudaMemcpy(Zsurfg  ,Zsurf  ,sizeof(float) *ListSize,cudaMemcpyHostToDevice); //It is done in UpdateZsurf().
      //-Copies data for BoxLimitg to GPU memory.
      if(UseBoxLimit){
        tfloat2* boxlimit=new tfloat2[ListSize*3];
        for(unsigned ci=0;ci<ListSize;ci++){
          const tfloat3 boxmin=List[ci]->GetBoxLimitMin();
          const tfloat3 boxmax=List[ci]->GetBoxLimitMax();
          boxlimit[ci]=TFloat2(boxmin.x,boxmax.x);
          boxlimit[ListSize+ci]=TFloat2(boxmin.y,boxmax.y);
          boxlimit[ListSize*2+ci]=TFloat2(boxmin.z,boxmax.z);
        }
        cudaMemcpy(BoxLimitg,boxlimit,sizeof(float2)*ListSize*3,cudaMemcpyHostToDevice);
        delete[] boxlimit; boxlimit=NULL;
      }
    }
  #endif

  //-Calculates total number of inout points and total number of inout particles.
  unsigned npt=0,npart=0;
  for(unsigned ci=0;ci<ListSize;ci++){
    npt+=List[ci]->GetNptInit();
    npart+=List[ci]->GetNpartInit();
  }

  //-Prepares data of points to refilling.
  if(UseRefilling){
    AllocatePtMemory(npt);
    npt=0;
    for(unsigned ci=0;ci<ListSize;ci++){
      const unsigned n=List[ci]->LoadInletPoints(PtPos+npt);
      memset(PtZone+npt,byte(List[ci]->GetIdZone()),sizeof(byte)*n);
      npt+=n;
    }
    #ifdef _WITHGPU
      if(!Cpu){
        //-Allocates and prepares auxiliary memory.
        tdouble2 *pxy=new tdouble2[PtCount];
        double   *pz =new double  [PtCount];
        for(unsigned c=0;c<PtCount;c++){
          pxy[c]=TDouble2(PtPos[c].x,PtPos[c].y);
          pz[c]=PtPos[c].z;
        }
        //-Copies data to GPU memory.
        cudaMemcpy(PtZoneg ,PtZone,sizeof(byte)   *PtCount,cudaMemcpyHostToDevice);
        cudaMemcpy(PtPosxyg,pxy   ,sizeof(double2)*PtCount,cudaMemcpyHostToDevice);
        cudaMemcpy(PtPoszg ,pz    ,sizeof(double) *PtCount,cudaMemcpyHostToDevice);
        //-Frees auxiliary memory.
        delete[] pxy; pxy=NULL;
        delete[] pz;  pz=NULL;
      }
    #endif

    //-Creates VTK file.
    if(DBG_INOUT_PTINIT){
      JFormatFiles2::StScalarData fields[8];
      unsigned nfields=0;
      if(PtZone){ fields[nfields]=JFormatFiles2::DefineField("PtZone"  ,JFormatFiles2::UChar8,1,PtZone);   nfields++; }
      const string filevtk=AppInfo.GetDirOut()+"CfgInOut_PtInit.vtk";
      JFormatFiles2::SaveVtk(filevtk,PtCount,PtPos,nfields,fields);
      Log->AddFileInfo(filevtk,"Saves initial InOut points for DEBUG (by JSphInOut).");
    }
    //-Creates VTK file.
    if(DBG_INOUT_PTINIT){
      unsigned npz=0;
      for(unsigned ci=0;ci<ListSize;ci++)npz+=List[ci]->GetCountPtzPos();
      if(npz){
        tfloat3 *pos =new tfloat3[npz];
        byte    *zone=new byte[npz];
        npz=0;
        for(unsigned ci=0;ci<ListSize;ci++){
          unsigned n=List[ci]->GetCountPtzPos();
          memcpy(pos+npz,List[ci]->GetPtzPos(),sizeof(tfloat3)*n);
          memset(zone+npz,byte(ci),sizeof(byte)*n);
          npz+=n;
        }
        JFormatFiles2::StScalarData fields[8];
        unsigned nfields=0;
        if(zone){ fields[nfields]=JFormatFiles2::DefineField("Zone"  ,JFormatFiles2::UChar8,1,zone);   nfields++; }
        const string filevtk=AppInfo.GetDirOut()+"CfgInOut_PtInitZ.vtk";
        JFormatFiles2::SaveVtk(filevtk,npz,pos,nfields,fields);
        Log->AddFileInfo(filevtk,"Saves initial InOut points for DEBUG (by JSphInOut).");
        //-Frees memory.
        delete[] pos;  pos=NULL;
        delete[] zone; zone=NULL;
      }
    }
  }

  //-Checks if some inlet configuration uses extrapolated data or variable velocity.
  VariableVel=false;
  VariableZsurf=false;
  CalculatedZsurf=false;
  ExtrapolatedData=false;
  NoExtrapolatedData=false;
  InterpolatedVel=false;
  for(unsigned ci=0;ci<GetCount();ci++){
    if(List[ci]->GetInterpolatedVel())InterpolatedVel=true;
    if(List[ci]->GetExtrapolatedData())ExtrapolatedData=true;
    if(List[ci]->GetNoExtrapolatedData())NoExtrapolatedData=true;
    if(List[ci]->GetVariableVel())VariableVel=true;
    if(List[ci]->GetVariableZsurf())VariableZsurf=true;
    if(List[ci]->GetCalculatedZsurf())CalculatedZsurf=true;
    if(!UseRefilling && List[ci]->GetRemoveZsurf())RunException(met,"Remove option in Zsurf is only allowed with UseRefilling=True.");
  }
  if((VariableZsurf || CalculatedZsurf) && !UseRefilling)RunException(met,"Zsurf variable or calculated is only allowed with UseRefilling=True.");
  return(npart);
}

//==============================================================================
/// Loads basic data (pos,idp,code,velrhop=0) for initial inout particles.
//==============================================================================
void JSphInOut::LoadInitPartsData(unsigned idpfirst,unsigned nparttot,unsigned* idp,typecode* code,tdouble3* pos,tfloat4* velrhop){
  const char met[]="LoadInitPartsData";
  //Log->Printf(" LoadInitPartsData--> nparttot:%u",nparttot);
  unsigned npart=0;
  for(unsigned ci=0;ci<GetCount();ci++){
    const unsigned np=List[ci]->GetNpartInit();
    //Log->Printf(" LoadInitPartsData--> np:%u  npart:%u",np,npart);
    if(npart+np>nparttot)RunException(met,"Number of initial inlet/outlet particles is invalid.");
    List[ci]->LoadInletParticles(pos+npart);
    for(unsigned cp=0;cp<np;cp++){
      const unsigned p=npart+cp;
      idp[p]=idpfirst+p;
      code[p]=typecode(CODE_TYPE_FLUID_INOUT)+ci;
      velrhop[p]=TFloat4(0);
    }
    npart+=np;
  }
  //Log->Printf(" LoadInitPartsData--> npart:%u",npart);
  if(npart!=nparttot)RunException(met,"Number of initial inlet/outlet particles is invalid.");
}

//==============================================================================
/// Creates list with particles in inlet/outlet zones. Also update code[] for
/// new inlet/outlet particles from normal fluid.
//==============================================================================
unsigned JSphInOut::CreateListCpu(unsigned nstep,unsigned npf,unsigned pini
  ,const tdouble3 *pos,const unsigned *idp,typecode *code,int *inoutpart)
{
  const char met[]="CreateListCpu";
  unsigned count=0;
  if(ListSize){
    const bool checkfreelimit=(UseBoxLimit && ListSize>2);
    const unsigned pfin=pini+npf;
    for(unsigned p=pini;p<pfin;p++){
      const typecode rcode=code[p];
      if(CODE_IsNormal(rcode) || CODE_IsPeriodic(rcode)){//-It includes normal and periodic particles.
        if(CODE_IsFluidInout(rcode)){//-Particles already selected as InOut.
          inoutpart[count]=p; count++;
        }
        else{
          const tfloat3 ps=ToTFloat3(pos[p]);
          if(!checkfreelimit || ps.x<=FreeLimitMin.x || FreeLimitMax.x<=ps.x || ps.z<=FreeLimitMin.z || FreeLimitMax.z<=ps.z || ps.y<=FreeLimitMin.y || FreeLimitMax.y<=ps.y){
            byte zone=255;
            for(unsigned cp=0;cp<ListSize && zone==255;cp++)
              if(JSphInOutZone::GetConfigConvertf(CfgZone[cp]) && List[cp]->InZone(UseBoxLimit,ps))zone=byte(cp);
            if(zone!=255){//-Particulas fluid que pasan a in/out.
              code[p]=CODE_ToFluidInout(rcode,zone);
              inoutpart[count]=p; count++;
            }
          }
        }
      }
    }
    if(0){ //DG_INOUT
      Log->Printf("AAA_000 ListSize:%u",ListSize);
      Log->Printf("AAA_000 Planes[0]:(%f,%f,%f,%f)",Planes[0].a,Planes[0].b,Planes[0].c,Planes[0].d);
      const float xini=-5.f;
      const float dp=0.01f;
      const unsigned np=1000;
      tfloat3 vpos[np];
      float vdis0[np];
      float vdis1[np];
      for(unsigned p=0;p<np;p++){
        vpos[p]=TFloat3(xini+dp*p,0,0);
        const float dis0=fgeo::PlanePoint(Planes[0],vpos[p]);
        vdis0[p]=(dis0<0? -1.f: (dis0>0? 1.f: 0));
        const float dis1=fgeo::PlanePoint(Planes[1],vpos[p]);
        vdis1[p]=(dis1<0? -1.f: (dis1>0? 1.f: 0));
      }
      //-Generates VTK file.
      JFormatFiles2::StScalarData fields[5];
      unsigned nfields=0;
      if(vdis0){ fields[nfields]=JFormatFiles2::DefineField("vdis0",JFormatFiles2::Float32,1,vdis0);    nfields++; }
      if(vdis1){ fields[nfields]=JFormatFiles2::DefineField("vdis1",JFormatFiles2::Float32,1,vdis1);    nfields++; }
      //string fname=DirOut+fun::FileNameSec("DgParts.vtk",numfile);
      JFormatFiles2::SaveVtk(AppInfo.GetDirOut()+"_Planes.vtk",np,vpos,nfields,fields);
    }
  }
  //Log->Printf("%u> -------->CreateListXXX>> InOutcount:%u",nstep,count);
  return(count);
}

#ifdef _WITHGPU
//==============================================================================
/// Creates list with particles in inlet/outlet zones. Also update code[] for
/// new inlet/outlet particles from fluid.
//==============================================================================
unsigned JSphInOut::CreateListGpu(unsigned nstep,unsigned npf,unsigned pini
  ,const double2 *posxyg,const double *poszg,typecode *codeg,unsigned size,int *inoutpartg)
{
  const char met[]="CreateListGpu";
  unsigned count=0;
  if(ListSize){
    if(npf+2>=size)RunException(met,"GPU memory allocated is not enough.");
    const tfloat3 freemin=(UseBoxLimit? FreeLimitMin: TFloat3(FLT_MAX));
    const tfloat3 freemax=(UseBoxLimit? FreeLimitMax: TFloat3(-FLT_MAX));
    count=cusphinout::InOutCreateList(Stable,npf,pini,byte(JSphInOutZone::ConvertFluid_MASK),byte(ListSize)
      ,CfgZoneg,Planesg,freemin,freemax,(UseBoxLimit? BoxLimitg: NULL),posxyg,poszg,codeg,(unsigned*)inoutpartg);
  }
  //Log->Printf("%u> -------->CreateListXXX>> InOutcount:%u",nstep,count);
  return(count);
}
#endif

//==============================================================================
/// Updates velocity coefficients for imposed velocity according timestep. 
/// Returns true when the data was changed.
//==============================================================================
bool JSphInOut::UpdateVelData(double timestep,bool full){
  bool modified=full;
  for(unsigned ci=0;ci<ListSize;ci++)if(full || List[ci]->GetVariableVel()){
    tfloat4 vel0,vel1;
    if(List[ci]->UpdateVelData(timestep,full,vel0,vel1)){
      modified=true;
      VelData[ci*2]=vel0;
      VelData[ci*2+1]=vel1;
    }
  }
  return(modified);
}

//==============================================================================
/// Updates zsurf according timestep. 
/// Returns true when the data was changed.
//==============================================================================
bool JSphInOut::UpdateZsurf(double timestep,bool full){
  const char met[]="UpdateZsurf";
  bool modified=full;
  for(unsigned ci=0;ci<ListSize;ci++)if(full || List[ci]->GetVariableZsurf() || List[ci]->GetCalculatedZsurf()){
    modified|=List[ci]->UpdateZsurf(timestep,full,Zsurf[ci]);
  }
  #ifdef _WITHGPU
    if(modified && !Cpu)cudaMemcpy(Zsurfg,Zsurf,sizeof(float)*ListSize,cudaMemcpyHostToDevice);
  #endif
  return(modified);
}

//==============================================================================
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//==============================================================================
void JSphInOut::UpdateDataCpu(float timestep,bool full,unsigned inoutcount,const int *inoutpart
  ,const tdouble3 *pos,const typecode *code,const unsigned *idp,tfloat4 *velrhop)
{
  const bool modifvel=UpdateVelData(timestep,full);
  //const bool modifzsurf=UpdateZsurf(timestep,full);
  const int ncp=int(inoutcount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cp=0;cp<ncp;cp++){
    const unsigned p=(unsigned)inoutpart[cp];
    const unsigned izone=CODE_GetIzoneFluidInout(code[p]);
    const byte cfg=CfgZone[izone];
    const double posz=pos[p].z;
    tfloat4 rvelrhop=velrhop[p];
    //-Compute rhop value.
    const JSphInOutZone::TpRhopMode rmode=JSphInOutZone::GetConfigRhopMode(cfg);
    if(rmode==JSphInOutZone::MRHOP_Constant)rvelrhop.w=RhopZero;
    if(rmode==JSphInOutZone::MRHOP_Hydrostatic){
      const float depth=float(double(Zsurf[izone])-posz);
      const float rh=1.f+CoefHydro*depth;     //rh=1.+rhop0*(-gravity.z)*(Dp*ptdata.GetDepth(p))/vCteB;
      rvelrhop.w=RhopZero*pow(rh,1.f/Gamma);  //rhop[id]=rhop0*pow(rh,(1./gamma));
    }
    //-Compute velocity value.
    const JSphInOutZone::TpVelMode    vmode=JSphInOutZone::GetConfigVelMode(cfg);
    const JSphInOutZone::TpVelProfile vprof=JSphInOutZone::GetConfigVelProfile(cfg);
    float vel=0;
    if(vmode==JSphInOutZone::MVEL_Fixed){
      vel=JSphInOutZone::CalcVel(vprof,VelData[izone*2],posz);
    }
    else if(vmode==JSphInOutZone::MVEL_Variable){
      const float vel1=JSphInOutZone::CalcVel(vprof,VelData[izone*2],posz);
      const float vel2=JSphInOutZone::CalcVel(vprof,VelData[izone*2+1],posz);
      const float time1=VelData[izone*2].w;
      const float time2=VelData[izone*2+1].w;
      if(timestep<=time1 || time1==time2)vel=vel1;
      else if(timestep>=time2)vel=vel2;
      else vel=(timestep-time1)/(time2-time1)*(vel2-vel1)+vel1;
    }
    if(vmode!=JSphInOutZone::MVEL_Extrapolated){
      rvelrhop.x=vel*DirData[izone].x;
      rvelrhop.y=vel*DirData[izone].y;
      rvelrhop.z=vel*DirData[izone].z;
    }
    velrhop[p]=rvelrhop;
  }
}

#ifdef _WITHGPU
//==============================================================================
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//==============================================================================
void JSphInOut::UpdateDataGpu(float timestep,bool full,unsigned inoutcount,const int *inoutpartg
  ,const double2 *posxyg,const double *poszg,const typecode *codeg,const unsigned *idpg,float4 *velrhopg)
{
  const bool modifvel=UpdateVelData(timestep,full);
  //const bool modifzsurf=UpdateZsurf(timestep,full);
  for(unsigned izone=0;izone<ListSize;izone++){
    const byte cfg=CfgZone[izone];
    const JSphInOutZone::TpRhopMode   rmode=JSphInOutZone::GetConfigRhopMode(cfg);
    const JSphInOutZone::TpVelMode    vmode=JSphInOutZone::GetConfigVelMode(cfg);
    const JSphInOutZone::TpVelProfile vprof=JSphInOutZone::GetConfigVelProfile(cfg);
    const byte brmode=(rmode==JSphInOutZone::MRHOP_Constant? 0: (rmode==JSphInOutZone::MRHOP_Hydrostatic? 1: (rmode==JSphInOutZone::MRHOP_Extrapolated? 2: 99)));
    const byte bvmode=(vmode==JSphInOutZone::MVEL_Fixed?     0: (vmode==JSphInOutZone::MVEL_Variable?     1: (vmode==JSphInOutZone::MVEL_Extrapolated?  2: 99)));
    const byte bvprof=(vprof==JSphInOutZone::PVEL_Constant?  0: (vprof==JSphInOutZone::PVEL_Linear?       1: (vprof==JSphInOutZone::PVEL_Parabolic?     2: 99)));
    cusphinout::InOutUpdateData(inoutcount,(unsigned*)inoutpartg
      ,byte(izone),brmode,bvmode,bvprof
      ,timestep,Zsurf[izone],VelData[izone*2],VelData[izone*2+1],DirData[izone]
      ,CoefHydro,RhopZero,Gamma,codeg,poszg,velrhopg);
  }
}
#endif

//==============================================================================
/// Interpolate velocity of inlet/outlet particles from data in InputVelGrid object.
/// Interpola velocidad de particulas inlet/outlet a partir de datos en el objeto InputVelGrid.
//==============================================================================
void JSphInOut::InterpolateVelCpu(float timestep,unsigned inoutcount,const int *inoutpart
  ,const tdouble3 *pos,const typecode *code,const unsigned *idp,tfloat4 *velrhop)
{
  for(unsigned ci=0;ci<GetCount();ci++)if(List[ci]->GetInterpolatedVel()){
    JSphInOutGridData* gd=List[ci]->GetInputVelGrid();
    if(gd->GetNx()==1)gd->InterpolateZVelCpu(timestep,byte(ci),inoutcount,inoutpart,pos,code,idp,velrhop);
    else gd->InterpolateVelCpu(timestep,byte(ci),inoutcount,inoutpart,pos,code,idp,velrhop);
  }
}

#ifdef _WITHGPU
//==============================================================================
/// Interpolate velocity of inlet/outlet particles from data in InputVelGrid object.
/// Interpola velocidad de particulas inlet/outlet a partir de datos en el objeto InputVelGrid.
//==============================================================================
void JSphInOut::InterpolateVelGpu(float timestep,unsigned inoutcount,const int *inoutpartg
  ,double2 *posxyg,double *poszg,typecode *codeg,unsigned *idpg,float4 *velrhopg)
{
  for(unsigned ci=0;ci<GetCount();ci++)if(List[ci]->GetInterpolatedVel()){
    JSphInOutGridData* gd=List[ci]->GetInputVelGrid();
    if(gd->GetNx()==1)gd->InterpolateZVelGpu(timestep,byte(ci),inoutcount,inoutpartg,posxyg,poszg,codeg,idpg,velrhopg);
    else RunException("InterpolateVelGpu","GPU code was not implemented for nx>1.");
  }
}
#endif

//==============================================================================
/// Removes interpolated Z velocity of inlet/outlet particles.
/// Elimina velocidad interpolada en Z de particulas inlet/outlet.
//==============================================================================
void JSphInOut::InterpolateResetZVelCpu(unsigned inoutcount,const int *inoutpart
  ,const typecode *code,tfloat4 *velrhop)
{
  for(unsigned ci=0;ci<GetCount();ci++)if(List[ci]->GetResetZVelGrid()){
    const JSphInOutGridData* gd=List[ci]->GetInputVelGrid();
    if(gd->GetUseVelz()){
      const int n=int(inoutcount);
      #ifdef OMP_USE
        #pragma omp parallel for schedule (static) if(n>OMP_LIMIT_COMPUTELIGHT)
      #endif
      for(int cp=0;cp<n;cp++){
        const unsigned p=inoutpart[cp];
        if(ci==CODE_GetIzoneFluidInout(code[p]))velrhop[p].z=0;
      }
    }
  }
}

#ifdef _WITHGPU
//==============================================================================
/// Removes interpolated Z velocity of inlet/outlet particles.
/// Elimina velocidad interpolada en Z de particulas inlet/outlet.
//==============================================================================
void JSphInOut::InterpolateResetZVelGpu(unsigned inoutcount,const int *inoutpartg
  ,typecode *codeg,float4 *velrhopg)
{
  for(unsigned ci=0;ci<GetCount();ci++)if(List[ci]->GetResetZVelGrid()){
    const JSphInOutGridData* gd=List[ci]->GetInputVelGrid();
    if(gd->GetUseVelz()){
      cusphinout::InOutInterpolateResetZVel(ci,inoutcount,inoutpartg,codeg,velrhopg);
    }
  }
}
#endif

//==============================================================================
/// ComputeStep over inout particles:
/// - If particle is moved to fluid zone then it changes to fluid particle and 
///   it creates a new inout particle.
/// - If particle is moved out the domain then it changes to ignore particle.
//==============================================================================
unsigned JSphInOut::ComputeStepCpu(unsigned nstep,double dt,unsigned inoutcount,int *inoutpart
  ,const JSphCpu *sphcpu,unsigned idnext,unsigned sizenp,unsigned np
  ,tdouble3 *pos,unsigned *dcell,typecode *code,unsigned *idp,tfloat4 *velrhop)
{
  const char met[]="ComputeStepCpu";
  //-Checks particle position.
  const int ncp=int(inoutcount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cp=0;cp<ncp;cp++){
    const unsigned p=(unsigned)inoutpart[cp];
    typecode rcode=code[p];
    const unsigned izone=CODE_GetIzoneFluidInout(rcode);
    const tfloat3 ps=ToTFloat3(pos[p]);
    const float displane=-fgeo::PlaneDistSign(Planes[izone],ps);
    if(displane>Width[izone]){//-Particle is moved out domain.
      code[p]=CODE_SetOutIgnore(rcode);
      inoutpart[cp]=INT_MAX;
    }
    else if(displane<0)inoutpart[cp]=-int(p);//-Particle is moved to normal fluid domain.
  }
  //-Create list for new inlet particles to create.
  unsigned inoutcount2=inoutcount;
  for(int cp=0;cp<ncp;cp++)if(inoutpart[cp]<0){
    if(inoutcount2<sizenp)inoutpart[inoutcount2]=-inoutpart[cp];
    inoutcount2++;
  }
  if(inoutcount2>=sizenp)RunException(met,"Allocated memory is not enough for new particles inlet.");
  //-Creates new inlet particles to replace the particles moved to fluid domain.
  const int newnp=int(inoutcount2-inoutcount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cp=0;cp<newnp;cp++){
    const unsigned p=(unsigned)inoutpart[inoutcount+cp];
    const unsigned izone=CODE_GetIzoneFluidInout(code[p]);
    code[p]=CodeNewPart;//-Particle changes to fluid particle.
    const double dis=Width[izone];
    tdouble3 rpos=pos[p];
    rpos.x-=dis*DirData[izone].x;
    rpos.y-=dis*DirData[izone].y;
    rpos.z-=dis*DirData[izone].z;
    const unsigned p2=np+cp;
    code[p2]=CODE_ToFluidInout(CodeNewPart,izone);
    sphcpu->UpdatePos(rpos,0,0,0,false,p2,pos,dcell,code);
    idp[p2]=idnext+cp;
    velrhop[p2]=TFloat4(0);
  }
  //-Returns number of new inlet particles.
  return(unsigned(newnp));
}

#ifdef _WITHGPU
//==============================================================================
/// ComputeStep over inlet/outlet particles:
/// - If particle is moved to fluid zone then it changes to fluid particle and 
///   it creates a new in/out particle.
/// - If particle is moved out the domain then it changes to ignore particle.
//==============================================================================
unsigned JSphInOut::ComputeStepGpu(unsigned nstep,double dt,unsigned inoutcount,int *inoutpartg
  ,unsigned idnext,unsigned sizenp,unsigned np
  ,double2 *posxyg,double *poszg,unsigned *dcellg,typecode *codeg,unsigned *idpg,float4 *velrhopg)
{
  const char met[]="ComputeStepGpu";
  //-Checks particle position.
  cusphinout::InOutComputeStep(PeriActive,inoutcount,inoutpartg,dt,Planesg,Widthg,velrhopg,posxyg,poszg,dcellg,codeg);
  //-Create list for new inlet particles to create.
  const unsigned newnp=cusphinout::InOutListCreate(Stable,inoutcount,sizenp-1,inoutpartg);
  if(inoutcount+newnp>=sizenp)RunException(met,"Allocated memory is not enough for new particles inlet.");
  //-Creates new inlet particles to replace the particles moved to fluid domain.
  cusphinout::InOutCreateNewInlet(PeriActive,newnp,((unsigned*)inoutpartg)+inoutcount,np,idnext,CodeNewPart,DirDatag,Widthg,posxyg,poszg,dcellg,codeg,idpg,velrhopg);
  //-Returns number of new inlet particles.
  //Log->Printf("%u> -------->ComputeStepXXX>> NewInletCount:%u",nstep,newnp);
  return(unsigned(newnp));
}
#endif

//==============================================================================
/// ComputeStep over inout particles and filling inout domain:
/// - If particle is moved to fluid zone then it changes to fluid particle and 
///   it creates a new inout particle.
/// - If particle is moved out the domain then it changes to ignore particle.
//==============================================================================
unsigned JSphInOut::ComputeStepFillingCpu(unsigned nstep,double dt,unsigned inoutcount,int *inoutpart
  ,const JSphCpu *sphcpu,unsigned idnext,unsigned sizenp,unsigned np
  ,tdouble3 *pos,unsigned *dcell,typecode *code,unsigned *idp,tfloat4 *velrhop
  ,float *prodist,tdouble3 *propos)
{
  const char met[]="ComputeStepFillingCpu";
  //-Updates position of particles and computes projection data to filling mode.
  const int ncp=int(inoutcount);
  memset(prodist,0,sizeof(float)*ncp);
  memset(propos,0,sizeof(tdouble3)*ncp);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cp=0;cp<ncp;cp++){
    const unsigned p=(unsigned)inoutpart[cp];
    const typecode rcode=code[p];
    const unsigned izone=CODE_GetIzoneFluidInout(rcode);
    const float displane=-fgeo::PlaneDistSign(Planes[izone],ToTFloat3(pos[p]));

    if(displane<0 || displane>Width[izone]){
      code[p]=(displane<0? CodeNewPart: CODE_SetOutIgnore(rcode));
      //-if (displane<0)inoutpart[cp]=-int(p); Particle changes to fluid particle.
      //-if (displane>Width[izone])inoutpart[cp]=INT_MAX; Particle is moved out in/out zone.
    }
    else{
      //prodist[cp]=(float)fgeo::PlaneDist(pla,pos[p]);
      prodist[cp]=displane;
      const tplane3d pla=TPlane3d(Planes[izone]);
      propos[cp]=fgeo::PlaneOrthogonalPoint(pos[p],pla);
    }
  }

  //-Removes particles above the Zsurf limit.
  if(UseRefilling)for(unsigned ci=0;ci<GetCount();ci++){
    const JSphInOutZone *izone=List[ci];
    if(izone->GetRemoveZsurf()){
      const float zsurf=izone->GetInputZsurf();
      const typecode codezone=CODE_ToFluidInout(CodeNewPart,ci);
      #ifdef OMP_USE
        #pragma omp parallel for schedule (static)
      #endif
      for(int cp=0;cp<ncp;cp++){
        const unsigned p=(unsigned)inoutpart[cp];
        if(code[p]==codezone && pos[p].z>zsurf){
          code[p]=CODE_SetOutIgnore(code[p]);
          prodist[cp]=0;
          propos[cp]=TDouble3(0);
        }
      }
    }
  }

  //-Compute maximum distance to create points in each PtPos.
  const bool checkzsurf=(VariableZsurf || CalculatedZsurf);
  const float dpmin=float(Dp*1);
  const float dpmin2=dpmin*dpmin;
  const int npt=int(PtCount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cpt=0;cpt<npt;cpt++){
    const tdouble3 ps=PtPos[cpt];
    float distmax=FLT_MAX;
    if(!checkzsurf || float(ps.z)<=Zsurf[PtZone[cpt]]){
      distmax=0;
      for(int cp=0;cp<ncp;cp++){
        const tfloat3 dis=ToTFloat3(ps-propos[cp]);
        if(dis.x<=dpmin && dis.y<=dpmin && dis.z<=dpmin){//-particle near to ptpoint (approx.)
          const float dist2=(dis.x*dis.x+dis.y*dis.y+dis.z*dis.z);
          if(dist2<dpmin2){//-particle near to ptpoint.
            const float dmax=prodist[cp]+sqrt(dpmin2-dist2);
            distmax=max(distmax,dmax);
          }
        }
      }
    }
    PtAuxDist[cpt]=(distmax==0? float(Dp): distmax);
  }

  //-Creates new inout particles.
  unsigned newnp=0;
//  for(int c=0;c<nc;c++)if(PtAuxDist[c]<Width[PtZone[c]]*0.99f){//-The 0.99 value avoids the creation of new particle to replace a removed particle in same step.
  for(int cpt=0;cpt<npt;cpt++)if(PtAuxDist[cpt]<Width[PtZone[cpt]]){
    const unsigned p=np+newnp;
    if(p<sizenp){
      const byte izone=PtZone[cpt];
      code[p]=CODE_ToFluidInout(CodeNewPart,izone);
      const double dis=PtAuxDist[cpt];
      tdouble3 rpos=PtPos[cpt];
      rpos.x-=dis*DirData[izone].x;
      rpos.y-=dis*DirData[izone].y;
      rpos.z-=dis*DirData[izone].z;
      sphcpu->UpdatePos(rpos,0,0,0,false,p,pos,dcell,code);
      idp[p]=idnext+newnp;
      velrhop[p]=TFloat4(0);
    }
    newnp++;
  }
  if(np+newnp>=sizenp)RunException(met,"Allocated memory is not enough for new particles inlet.");

  //-Returns number of new inlet particles.
  //Log->Printf("%u> -------->ComputeStepFillingXXX>> NewInletCount:%u",nstep,newnp);
  return(newnp);
}
  
#ifdef _WITHGPU
//==============================================================================
/// ComputeStep over inlet/outlet particles:
/// - If particle is moved to fluid zone then it changes to fluid particle and 
///   it creates a new in/out particle.
/// - If particle is moved out the domain then it changes to ignore particle.
//==============================================================================
unsigned JSphInOut::ComputeStepFillingGpu(unsigned nstep,double dt,unsigned inoutcount,int *inoutpartg
  ,unsigned idnext,unsigned sizenp,unsigned np
  ,double2 *posxyg,double *poszg,unsigned *dcellg,typecode *codeg,unsigned *idpg,float4 *velrhopg
  ,float *prodistg,double2 *proposxyg,double *proposzg)
{
  const char met[]="ComputeStepFillingGpu";
  //-Computes projection data to filling mode.
  cusphinout::InOutFillProjection(inoutcount,(unsigned *)inoutpartg,CodeNewPart,Planesg,Widthg,posxyg,poszg
    ,codeg,prodistg,proposxyg,proposzg);

  //-Removes particles above the Zsurf limit.
  if(UseRefilling)for(unsigned ci=0;ci<GetCount();ci++){
    const JSphInOutZone *izone=List[ci];
    if(izone->GetRemoveZsurf()){
      const float zsurf=izone->GetInputZsurf();
      const typecode codezone=CODE_ToFluidInout(CodeNewPart,ci);
      cusphinout::InOutRemoveZsurf(inoutcount,(unsigned *)inoutpartg,codezone,zsurf,poszg,codeg,prodistg,proposxyg,proposzg);
    }
  }

  //-Create list of selected ptpoints and its distance to create new inlet/outlet particles.
  const float dpmin=float(Dp*1);
  const float dpmin2=dpmin*dpmin;
  const unsigned newnp=cusphinout::InOutFillListCreate(Stable,PtCount,PtPosxyg,PtPoszg
    ,PtZoneg,Zsurfg,Widthg,inoutcount,prodistg,proposxyg,proposzg
    ,dpmin,dpmin2,float(Dp),PtAuxDistg,sizenp-1,(unsigned*)inoutpartg);
  //-Creates new inlet/outlet particles to fill inlet/outlet domain.
  cusphinout::InOutFillCreate(PeriActive,newnp,(unsigned *)inoutpartg,PtPosxyg,PtPoszg,PtZoneg,PtAuxDistg
    ,np,idnext,CodeNewPart,DirDatag,posxyg,poszg,dcellg,codeg,idpg,velrhopg);
  //-Returns number of new inlet particles.
  //Log->Printf("%u> -------->ComputeStepFillingXXX>> NewInletCount:%u",nstep,newnp);
  return(newnp);
}
#endif

//==============================================================================
/// Updates velocity and rhop for M1 variable when Verlet is used. 
/// Actualiza velocidad y densidad de varible M1 cuando se usa Verlet.
//==============================================================================
void JSphInOut::UpdateVelrhopM1Cpu(unsigned inoutcount,const int *inoutpart
  ,const tfloat4 *velrhop,tfloat4 *velrhopm1)
{
  const int ncp=int(inoutcount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static) if(ncp>OMP_LIMIT_COMPUTELIGHT)
  #endif
  for(int cp=0;cp<ncp;cp++){
    const unsigned p=(unsigned)inoutpart[cp];
    velrhopm1[p]=velrhop[p];
  }
}

#ifdef _WITHGPU
//==============================================================================
/// Updates velocity and rhop for M1 variable when Verlet is used. 
/// Actualiza velocidad y densidad de varible M1 cuando se usa Verlet.
//==============================================================================
void JSphInOut::UpdateVelrhopM1Gpu(unsigned inoutcount,const int *inoutpartg
  ,const float4 *velrhopg,float4 *velrhopm1g)
{
  cusphinout::InOutUpdateVelrhopM1(inoutcount,inoutpartg,velrhopg,velrhopm1g);
}
#endif


//==============================================================================
/// Reset interaction varibles (ace,ar,shiftpos) over inout particles.
/// Pone a cero las variables de la interaccion (ace,ar,shiftpos) de las particulas inout.
//==============================================================================
void JSphInOut::ClearInteractionVarsCpu(unsigned inoutcount,const int *inoutpart
    ,tfloat3 *ace,float *ar,tfloat3 *shiftpos)
{
  if(ace==NULL || ar==NULL)RunException("ClearInteractionVarsCpu","Some pointer is NULL.");
  const tfloat3 zero3=TFloat3(0);
  const int ncp=int(inoutcount);
  #ifdef OMP_USE
    #pragma omp parallel for schedule (static)
  #endif
  for(int cp=0;cp<ncp;cp++){
    const unsigned p=(unsigned)inoutpart[cp];
    ace[p]=zero3;
    ar[p]=0;
    if(shiftpos)shiftpos[p]=zero3;
  }
}

#ifdef _WITHGPU
//==============================================================================
/// Reset interaction varibles (ace,ar,shiftpos) over inout particles.
/// Pone a cero las variables de la interaccion (ace,ar,shiftpos) de las particulas inout.
//==============================================================================
void JSphInOut::ClearInteractionVarsGpu(unsigned inoutcount,const int *inoutpartg
    ,float3 *aceg,float *arg,float *viscdtg,float3 *shiftposg)
{
  if(aceg==NULL || arg==NULL || viscdtg==NULL)RunException("ClearInteractionVarsGpu","Some pointer is NULL.");
  cusphinout::InoutClearInteractionVars(inoutcount,inoutpartg,aceg,arg,viscdtg,shiftposg);
}
#endif


//==============================================================================
/// Shows object configuration using Log.
//==============================================================================
void JSphInOut::VisuConfig(std::string txhead,std::string txfoot)const{
  if(!txhead.empty())Log->Print(txhead);
  Log->Printf("UseRefilling: %s",(UseRefilling? "True": "False"));
  Log->Printf("UseBoxLimit: %s",(UseBoxLimit? "True": "False"));
  if(UseBoxLimit)Log->Printf("  FreeLimits:%s  FreeCentre:(%s)",fun::Float3xRangeStr(FreeLimitMin,FreeLimitMax,"%g").c_str(),fun::Float3gStr(FreeCentre).c_str());
  Log->Printf("DetermLimit.: %g %s",DetermLimit,(DetermLimit==1e-3f? "(1st order)": (DetermLimit==1e+3f? "(0th order)": " ")));
  Log->Printf("ExtrapolateMode: %s",(ExtrapolateMode==1? "FastSingle": (ExtrapolateMode==2? "Single": (ExtrapolateMode==3? "Double": "???"))));
  for(unsigned ci=0;ci<GetCount();ci++){
    JSphInOutZone *izone=List[ci];
    Log->Printf("InOut_%u",izone->GetIdZone());
    std::vector<std::string> lines;
    izone->GetConfig(lines);
    for(unsigned i=0;i<unsigned(lines.size());i++)Log->Print(string("  ")+lines[i]);
  }
  if(!txfoot.empty())Log->Print(txfoot);
}

//==============================================================================
/// Creates VTK files with Zsurf.
//==============================================================================
void JSphInOut::SaveVtkZsurf(unsigned part){
  std::vector<JFormatFiles2::StShapeData> shapes;
  for(unsigned ci=0;ci<GetCount();ci++){
    const JSphInOutZone *izone=List[ci];
    if(izone->GetSvVtkZsurf()){
      const float zsurf=izone->GetInputZsurf();
      //const tdouble3* ptdom=izone->GetPtDomain();
      tfloat3 boxmin=List[ci]->GetBoxLimitMin();
      tfloat3 boxmax=List[ci]->GetBoxLimitMax();
      if(Simulate2D){
        const float py=float(Simulate2DPosY);
        const tfloat3 pt1=TFloat3(boxmin.x,py,zsurf);
        const tfloat3 pt2=TFloat3(boxmax.x,py,zsurf);
        shapes.push_back(JFormatFiles2::DefineShape_Line(pt1,pt2,ci,0));
      }
      else{
        boxmin.z=boxmax.z=zsurf;
        const tfloat3 pt1=TFloat3(boxmax.x,boxmin.y,boxmin.z);
        const tfloat3 pt2=TFloat3(boxmin.x,boxmax.y,boxmax.z);
        shapes.push_back(JFormatFiles2::DefineShape_Quad(boxmin,pt1,boxmax,pt2,ci,0));
      }
    }
  }
  if(shapes.size()>0){
    const string filevtk=AppInfo.GetDirDataOut()+"InOut_Zsurf.vtk";
    JFormatFiles2::SaveVtkShapes(fun::FileNameSec(filevtk,part),"izone","",shapes);
    Log->AddFileInfo(filevtk,"Saves VTK files with Zsurf (by JSphInOut).");
  }
}

//==============================================================================
/// Calculates number of particles to resize memory.
//==============================================================================
unsigned JSphInOut::CalcResizeNp(double timestep)const{
  const char met[]="CalcResizeNp";
  unsigned newp=0;
  for(unsigned ci=0;ci<GetCount();ci++)newp+=List[ci]->CalcResizeNp(timestep,ResizeTime);
  return(newp);
}




